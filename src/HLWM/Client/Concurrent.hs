{-# LANGUAGE LambdaCase, RecordWildCards #-}

-- | A concurrent client implementation of the
-- <http://herbstluftwm.org herbstluftwm>window manager.
--
-- See "HLWM.Client.IPC" for details and examples. This module removes the
-- restriction that nextHook and sendCommand can't be called concurrently.
--
-- Note that the low-level event handling API from "HLWM.Client.IPC" is not
-- exported here, because it is not needed. Use haskell's built-in concurrency
-- features instead. For example, an asynchronous command can be sent with:
--
-- > withConnection $ \con -> do
-- >   var <- newEmptyMVar
-- >   forkIO $ sendCommand con ["echo","foo"] >>= putMVar var
-- >   -- do some stuff ...
-- >   -- finally read output
-- >   output <- takeMVar var

module HLWM.Client.Concurrent
       ( -- * Connection
         HerbstConnection
       , connect
       , disconnect
       , withConnection
         -- * Commands and Hooks
       , sendCommand
       , nextHook
       ) where

import HLWM.Client.IPC (HerbstEvent(..))
import qualified HLWM.Client.IPC as IPC

import Control.Concurrent.STM
import Control.Concurrent
import Control.Monad
import Data.Maybe

-- | Opaque type representing the connection to the herbstluftwm server
--
-- See 'connect' and 'disconnect'.
data HerbstConnection = HerbstConnection {
  connection :: IPC.HerbstConnection,
  commandLock :: Lock,
  eventChan :: TChan HerbstEvent,
  eventThreadId :: ThreadId
}

-- | Connect to the herbstluftwm server.
--
-- Be sure to call 'disconnect' if you don't need the connection anymore, to
-- free any allocated resources. When in doubt, call 'withConnection'.
--
-- Note that there must not be more than one connection open at any time!
connect :: IO (Maybe HerbstConnection)
connect = IPC.connect >>= \case
  Nothing -> return Nothing
  Just connection -> do
    commandLock <- newEmptyTMVarIO
    eventChan <- newBroadcastTChanIO
    eventThreadId <- forkIO $ eventThread connection eventChan
    return $ Just $ HerbstConnection {..}

-- | Close connection to the herbstluftwm server.
--
-- After calling this function, the 'HerbstConnection' is no longer valid and
-- must not be used anymore.
--
-- __Bug:__ Currently blocks until another event is received.

-- FIXME Get killThread to work, even if it blocks in recvEvent
disconnect :: HerbstConnection -> IO ()
disconnect HerbstConnection{..} = do
  atomically $ lock commandLock
  killThread eventThreadId
  IPC.disconnect connection

-- | Execute an action with a newly established 'HerbstConnection'.
--
-- Connects to the herbstluftwm server, passes the connection on to the supplied
-- action and closes the connection again after the action has finished.

-- FIXME: Add exception safety
withConnection :: (HerbstConnection -> IO a) -> IO (Maybe a)
withConnection f = connect >>= \case
  Just con -> do
    res <- f con
    disconnect con
    return $ Just res
  Nothing -> return Nothing

-- | Execute a command in the herbstluftwm server.
--
-- Send a command consisting of a list of Strings to the server and wait for the
-- response. Herbstluftwm interprets this list as a command followed by a number
-- of arguments. Returns a tuple of the exit status and output of the called
-- command.
sendCommand :: HerbstConnection -> [String] -> IO (Int, String)
sendCommand client args = do
  events <- atomically $ do
    lock (commandLock client)
    dupTChan (eventChan client)
  IPC.asyncSendCommand (connection client) args
  res <- readBoth events Nothing Nothing
  atomically $ unlock (commandLock client)
  return res

  where readBoth _ (Just s) (Just o) = return (o,s)
        readBoth events a b = atomically (readTChan events) >>= \case
          OutputEvent o | isNothing a -> readBoth events (Just o) b
          StatusEvent s | isNothing b -> readBoth events a (Just s)
          _ -> readBoth events a b

-- | Wait for a hook event from the server and return it.
--
-- A hook is just an arbitrary list of strings generated by herbstluftwm or its
-- clients.
nextHook :: HerbstConnection -> IO [String]
nextHook client = do
  chan <- atomically $ dupTChan (eventChan client)

  let loop = atomically (readTChan chan) >>= \case
        HookEvent res -> return res
        _             -> loop

  loop

eventThread :: IPC.HerbstConnection -> TChan HerbstEvent -> IO ()
eventThread con chan = forever $ do
  ev <- IPC.recvEvent con
  atomically $ writeTChan chan ev

type Lock = TMVar ()

lock :: TMVar () -> STM ()
lock l = putTMVar l ()

unlock :: TMVar () -> STM ()
unlock l = takeTMVar l >> return ()
