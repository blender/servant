-- | This module contains wrappers around lower-level functionality.
module Servant.CoMock.Internal.CoMock where

import           Control.Concurrent.MVar  (modifyMVar_, readMVar)
import           Control.Monad            (replicateM_)
import           Data.Proxy               (Proxy)
import           Data.Void                (Void)
import           Network.HTTP.Client      (Manager, defaultManagerSettings,
                                           newManager)
import           Network.HTTP.Client      (managerModifyRequest, getUri)
import           Network.Wai.Handler.Warp (withApplication)
import           Servant                  (HasServer, Server, serve)
import           Servant.Client           (BaseUrl (..), Client, HasClient,
                                           Scheme (..), ServantError, client)
import           System.IO                (hPutStrLn)
import           System.IO.Temp           (withSystemTempFile)
import           System.Process           (callCommand)
import           Test.Hspec               (Expectation, expectationFailure)
import           Test.QuickCheck          (Args (..), Property, Result (..),
                                           Testable, property,
                                           quickCheckWithResult, stdArgs)

import Servant.CoMock.Internal.Testable
import Servant.CoMock.Internal.Predicates
import Servant.CoMock.Internal.Benchmarking


-- | Start a servant application on an open port, run the provided function,
-- then stop the application.
withServantServer :: HasServer a '[] => Proxy a -> IO (Server a)
  -> (BaseUrl -> IO r) -> IO r
withServantServer api server t
  = withApplication (return . serve api =<< server) $ \port ->
      t (BaseUrl Http "localhost" port "")

-- | A QuickCheck 'Property' that randomly generates arguments (captures, query
-- params, request bodies, headers, etc.) expected by endpoints of a server,
-- and makes requests to the servers running in the two provided URLs in the
-- same order, failing if they do not return the same response.
--
-- Evidently, if the behaviour of the server is expected to be
-- non-deterministic,  this function may produce spurious failures.
--
-- Note that this QuickCheck 'Property' does IO; interleaving it with other IO
-- actions will not work. It is provided so that it can be used with QuickCheck
-- functions such as 'quickCheckWith'. For most use cases, you should use
-- @serversEqual@ or @servantServersEqual@.
serversEqualProperty :: (HasClient a, Testable (ShouldMatch (Client a)))
    => Proxy a -> Manager -> BaseUrl -> BaseUrl -> Property
serversEqualProperty api mgr burl1 burl2 = property $ ShouldMatch c1 c2
  where c1 = client api burl1 mgr
        c2 = client api burl2 mgr

-- | Check that the two servers running under the provided @BaseUrl@s behave
-- identically by randomly generating arguments (captures, query params, request bodies,
-- headers, etc.) expected by the server. If, given the same request, the
-- response is not the same (according to the definition of @==@ for the return
-- datatype), the 'Expectation' fails, printing the counterexample.
--
-- The @Int@ argument specifies maximum number of test cases to generate and
-- run.
--
-- Evidently, if the behaviour of the server is expected to be
-- non-deterministic,  this function may produce spurious failures.
serversEqual :: (HasClient a, Testable (ShouldMatch (Client a)))
    => Proxy a -> BaseUrl -> BaseUrl -> Int -> Expectation
serversEqual api burl1 burl2 tries = do
    mgr <- managerWithStoredReq
    let args = stdArgs { chatty = False, maxSuccess = tries }
    res <- quickCheckWithResult args $ serversEqualProperty api mgr burl1 burl2
    case res of
      Success _ _ _ -> return ()
      _             -> prettyErr >>= expectationFailure


serverSatisfiesProperty :: (HasClient a, Testable (ShouldSatisfy filt exp (Client a)))
    => Proxy a -> Manager -> BaseUrl -> Predicates filt -> Predicates exp -> Property
serverSatisfiesProperty api mgr burl filters expect = do
    property $ ShouldSatisfy (client api burl mgr) filters expect

-- | Check that a server's responses satisfies certain properties.
serverSatisfies :: (HasClient a, Testable (ShouldSatisfy filt exp (Client a)))
    => Proxy a -> BaseUrl -> Predicates filt -> Predicates exp
    -> Int -> Expectation
serverSatisfies api burl filters expect tries = do
    mgr <- managerWithStoredReq
    let args = stdArgs { chatty = False, maxSuccess = tries }
    res <- quickCheckWithResult args $ serverSatisfiesProperty api mgr burl filters expect
    case res of
      Success _ _ _ -> return ()
      GaveUp n _ _  -> expectationFailure $ "Gave up after " ++ show n ++ " tests"
      _             -> prettyErr >>= expectationFailure

-- | Check that the two servers running under the provided @BaseUrl@s do not
-- behave identically.
--
-- As with @serversEqualProperty@, non-determinism in the servers will likely
-- result in failures that may not be significant.
serversUnequal :: (HasClient a, Testable (ShouldMatch (Client a)))
    => Proxy a -> BaseUrl -> BaseUrl -> Int -> Expectation
serversUnequal api burl1 burl2 tries = do
    mgr <- managerWithStoredReq
    let args = stdArgs { chatty = False, maxSuccess = tries }
    res <- quickCheckWithResult args $ serversEqualProperty api mgr burl1 burl2
    case res of
      Success _ _ _ -> prettyErr >>= expectationFailure
      _             -> return ()

serverDoesntSatisfy :: (HasClient a, Testable (ShouldSatisfy filt exp (Client a)))
    => Proxy a -> BaseUrl -> Predicates filt -> Predicates exp
    -> Int -> Expectation
serverDoesntSatisfy api burl filters expect tries = do
    mgr <- managerWithStoredReq
    let args = stdArgs { chatty = False, maxSuccess = tries }
    res <- quickCheckWithResult args $ serverSatisfiesProperty api mgr burl filters expect
    case res of
      Success _ _ _ -> prettyErr >>= expectationFailure
      _             -> return ()

serverBenchmark :: (HasClient a, Testable (ShouldSatisfy '[] '[Either ServantError Void] (Client a)))
    => Proxy a -> BaseUrl -> BenchOptions -> IO ()
serverBenchmark api burl opts = replicateM_ (noOfTests opts) go
  where
    go = do
      serverSatisfies api burl emptyPredicates (addLeftPredicate (const True) emptyPredicates) 1
      Just (r, _) <- readMVar currentReq
      withSystemTempFile "wrkscript.lua" $ \f h -> do
        let url = show $ getUri r
            s   = mkScript $ reqToWrk r
            c   = "wrk -c" ++ show (connections opts)
               ++ " -d" ++ show (duration opts) ++ "s "
               ++ " --script \"" ++ f ++ "\" "
               ++ url
        putStrLn $ "Calling command: " ++ c
        putStrLn $ "With script:\n" ++ s ++ "\n\n"
        hPutStrLn h s
        callCommand c

managerWithStoredReq :: IO Manager
managerWithStoredReq = newManager defaultManagerSettings { managerModifyRequest = go }
  where go req = modifyMVar_ currentReq (addReq req) >> return req
        addReq req _ = return $ Just (req, "")
