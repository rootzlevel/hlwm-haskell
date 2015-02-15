{-# LANGUAGE RecordWildCards, LambdaCase, MultiWayIf, TupleSections, BangPatterns, ScopedTypeVariables, Rank2Types #-}

-- | A client implementation of the <http://herbstluftwm.org herbstluftwm>
-- window manager.
--
-- See <http://herbstluftwm.org/herbstluftwm.html herbstluftwm(1)> and
-- <http://herbstluftwm.org/herbstclient.html herbstclient(1)> for what this is
-- all about.
--
-- == Examples
-- Sending a command to herbstluftwm:
--
-- >>> withConnection (\con -> sendCommand con ["echo", "foo"])
-- Just (0,"foo\n")
--
-- Printing 2 hooks:
--
-- >>> withConnection (\con -> replicateM_ 2 $ unwords <$> nextHook con >>= putStrLn)
-- focus_changed 0x340004c IPC.hs - emacs
-- focus_changed 0x3200073 ROXTerm
-- Just ()
--
-- == On event handling
--
-- There is a single function 'recvEvent', that returns all events received by
-- herbstluftwm in order. The high-level functions 'sendCommand' and 'nextHook'
-- work by calling 'recvEvent' until they get the event they expected and
-- discarding all other events received in the meantime. This means that it is
-- not possible to call 'nextHook' and 'sendCommand' concurrently in different
-- threads. Also, when calling 'asyncSendCommand' and then 'nextHook', the
-- output of the command will likely be thrown away.
--
-- See "HLWM.Client.Concurrent" for an interface that allows concurrent calling
-- of 'nextHook' and 'sendCommand'.

module HLWM.IPC.Internal
       ( -- * Connection
         HerbstConnection(..)
       , connect
       , disconnect
       , withConnection
         -- * High level interface
       , sendCommand
       , nextHook
         -- * Event handling
       , recvEvent
       , tryRecvEvent
       , HerbstEvent(..)
       , asyncSendCommand
       ) where

import Graphics.X11.Xlib
import Graphics.X11.Xlib.Extras
import Graphics.X11.Xlib.Herbst
import Control.Applicative
import Foreign.C.String
import Data.Bits
import Data.Maybe
import Control.Exception

-- | Opaque type representing the connection to the herbstluftwm server
--
-- See 'connect' and 'disconnect'.
data HerbstConnection = HerbstConnection {
  display :: Display,
  atomArgs :: Atom,
  atomOutput :: Atom,
  atomStatus :: Atom,
  root :: Window,
  hooksWin :: Window,
  clientWin :: Window
}

herbstIPCArgsAtom :: String
herbstIPCArgsAtom = "_HERBST_IPC_ARGS"

herbstIPCOutputAtom :: String
herbstIPCOutputAtom = "_HERBST_IPC_OUTPUT"

herbstIPCStatusAtom :: String
herbstIPCStatusAtom = "_HERBST_IPC_EXIT_STATUS"

herbstIPCClass :: String
herbstIPCClass = "HERBST_IPC_CLASS"

herbstHookWinIdAtom :: String
herbstHookWinIdAtom = "__HERBST_HOOK_WIN_ID"

-- | Connect to the herbstluftwm server.
--
-- Be sure to call 'disconnect' if you don't need the connection anymore, to
-- free any allocated resources. When in doubt, call 'withConnection'.
connect :: IO (Maybe HerbstConnection)
connect = do
  display <- openDefaultDisplay

  let root = defaultRootWindow display
  atomArgs <- internAtom display herbstIPCArgsAtom False
  atomOutput <- internAtom display herbstIPCOutputAtom False
  atomStatus <- internAtom display herbstIPCStatusAtom False


  clientWin <- createClientWindow display root
  findHookWindow display root >>= \case
    Just hooksWin -> flush display >> (return $ Just $ HerbstConnection {..})
    Nothing -> do
      destroyClientWindow display clientWin
      closeDisplay display
      return Nothing


-- | Close connection to the herbstluftwm server.
--
-- After calling this function, the 'HerbstConnection' is no longer valid and
-- must not be used anymore.
disconnect :: HerbstConnection -> IO ()
disconnect con = do
  destroyClientWindow (display con) (clientWin con)
  closeDisplay (display con)

createClientWindow :: Display -> Window -> IO Window
createClientWindow display root = do
  grabServer display

  win <- createSimpleWindow display root 42 42 42 42 0 0 0

  setClassHint display win $
    (ClassHint herbstIPCClass herbstIPCClass)

  selectInput display win propertyChangeMask

  ungrabServer display

  return win

destroyClientWindow :: Display -> Window -> IO ()
destroyClientWindow d win = destroyWindow d win

findHookWindow :: Display -> Window -> IO (Maybe Window)
findHookWindow display root = do
  atom <- internAtom display herbstHookWinIdAtom False
  getWindowProperty32 display atom root >>= \case
    Just (winid:_) -> do
      let win = fromIntegral winid
          inputMask = structureNotifyMask .|. propertyChangeMask

      selectInput display win inputMask

      return $ Just win
    _ -> return Nothing

-- | Send a command to the server, but don't wait for the response.
--
-- Like 'sendCommand', but it's the callers responsibility to manually receive
-- the output of the command with 'recvEvent'.
--
-- Note, that it is not possible to relate asynchronous command calls with
-- responses returned by 'recvEvent', apart from the order in which they are
-- received.
asyncSendCommand :: HerbstConnection -> [String] -> IO ()
asyncSendCommand con args = do
  textProp <- utf8TextListToTextProperty (display con) args
  setTextProperty' (display con) (clientWin con) textProp (atomArgs con)
  flush (display con)

-- | The type of events generated by herbstluftwm.
data HerbstEvent = HookEvent [String]
                 | StatusEvent Int
                 | OutputEvent String

-- | Read a HerbstEvent, if one is pending
tryRecvEvent :: HerbstConnection -> IO (Maybe HerbstEvent)
tryRecvEvent con = do
  pending (display con) >>= \case
    0 -> return Nothing
    _ -> Just <$> recvEvent con

-- | Wait for the next HerbstEvent in the queue and return it.
recvEvent :: HerbstConnection -> IO HerbstEvent
recvEvent con = allocaXEvent eventLoop
  where eventLoop :: XEventPtr -> IO HerbstEvent
        eventLoop event = do
          nextEvent (display con) event
          getEvent event >>= \case
            PropertyEvent{..}
              | ev_window == (clientWin con) && ev_atom == (atomOutput con) ->
                  readOutput >>= cont event OutputEvent
              | ev_window == (clientWin con) && ev_atom == (atomStatus con) ->
                  readStatus >>= cont event StatusEvent
              | ev_window == (hooksWin con) && ev_propstate /= propertyDelete ->
                  readHook ev_atom >>= cont event HookEvent
            _ -> eventLoop event

        cont :: XEventPtr -> (a -> HerbstEvent) -> Maybe a -> IO HerbstEvent
        cont event f = maybe (eventLoop event) (return . f)

        readOutput :: IO (Maybe String)
        readOutput = do
          tp <- getTextProperty (display con) (clientWin con) (atomOutput con)
          utf8str <- internAtom (display con) "UTF8_STRING" False
          if tp_encoding tp == sTRING || tp_encoding tp == utf8str
            then Just <$> peekCString (tp_value tp)
            else return Nothing

        readStatus :: IO (Maybe Int)
        readStatus = fmap (fromIntegral . head) <$>
          getWindowProperty32 (display con) (atomStatus con) (clientWin con)

        readHook :: Atom -> IO (Maybe [String])
        readHook atom = do
          prop <- getTextProperty (display con) (hooksWin con) atom
          Just <$> utf8TextPropertyToTextList (display con) prop

recvCommandOutput :: HerbstConnection -> IO (Int, String)
recvCommandOutput con = readBoth Nothing Nothing
  where readBoth (Just s) (Just o) = return (o,s)
        readBoth a b = recvEvent con >>= \case
          OutputEvent o | isNothing a -> readBoth (Just o) b
          StatusEvent s | isNothing b -> readBoth a (Just s)
          _ -> readBoth a b

-- | Execute a command in the herbstluftwm server.
--
-- Send a command consisting of a list of Strings to the server and wait for the
-- response. Herbstluftwm interprets this list as a command followed by a number
-- of arguments. Returns a tuple of the exit status and output of the called
-- command.
--
-- __Warning:__ This discards any events received from the server that are not
-- the response to the command. In particular, any hook events received while
-- waiting for the response will be thrown away.
sendCommand :: HerbstConnection -> [String] -> IO (Int, String)
sendCommand con args = do
  asyncSendCommand con args
  recvCommandOutput con

-- | Wait for a hook event from the server and return it.
--
-- A hook is just an arbitrary list of strings generated by herbstluftwm or its
-- clients.
--
-- __Warning:__ This discards any events received from the server that are not
-- hook events. In particular, any responses to commands called by
-- 'asyncSendCommand' received while waiting for the hook will be thrown away.
nextHook :: HerbstConnection -> IO [String]
nextHook con = recvEvent con >>= \case
  HookEvent r -> return r
  _           -> nextHook con

-- | Execute an action with a newly established 'HerbstConnection'.
--
-- Connects to the herbstluftwm server, passes the connection on to the supplied
-- action and closes the connection again after the action has finished.
withConnection :: (HerbstConnection -> IO a) -> IO (Maybe a)
withConnection f =
  bracket connect (maybe (return ()) disconnect)
                  (maybe (return Nothing) (fmap Just . f))