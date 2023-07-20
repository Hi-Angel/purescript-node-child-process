-- | This module contains various types and functions to allow you to spawn and
-- | interact with child processes.
-- |
-- | It is intended to be imported qualified, as follows:
-- |
-- | ```purescript
-- | import Node.ChildProcess (ChildProcess, CHILD_PROCESS)
-- | import Node.ChildProcess as ChildProcess
-- | ```
-- |
-- | The [Node.js documentation](https://nodejs.org/api/child_process.html)
-- | forms the basis for this module and has in-depth documentation about
-- | runtime behaviour.
module Node.ChildProcess
  ( Handle
  , ChildProcess
  , toEventEmitter
  , closeH
  , disconnectH
  , errorH
  , exitH
  , messageH
  , spawnH
  , stdin
  , stdout
  , stderr
  , pid
  , connected
  , disconnect
  , exitCode
  , kill
  , kill'
  , killSignal
  , killed
  , signalCode
  , send
  , Exit(..)
  , spawn
  , SpawnOptions
  , defaultSpawnOptions
  , exec
  , execFile
  , ExecOptions
  , ExecResult
  , defaultExecOptions
  , execSync
  , execFileSync
  , ExecSyncOptions
  , defaultExecSyncOptions
  , fork
  , StdIOBehaviour(..)
  , pipe
  , inherit
  , ignore
  ) where

import Prelude

import Data.Function.Uncurried (Fn2, runFn2)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Nullable (Nullable, toMaybe, toNullable)
import Data.Posix (Pid, Gid, Uid)
import Data.Posix.Signal (Signal)
import Data.Posix.Signal as Signal
import Effect (Effect)
import Effect.Exception as Exception
import Effect.Uncurried (EffectFn1, EffectFn2, mkEffectFn1, mkEffectFn2, runEffectFn1, runEffectFn2)
import Foreign (Foreign)
import Foreign.Object (Object)
import Node.Buffer (Buffer)
import Node.Encoding (Encoding, encodingToNode)
import Node.Errors.SystemError (SystemError)
import Node.EventEmitter (EventEmitter, EventHandle(..))
import Node.EventEmitter.UtilTypes (EventHandle0, EventHandle1)
import Node.FS as FS
import Node.Stream (Readable, Stream, Writable)
import Partial.Unsafe (unsafeCrashWith)
import Unsafe.Coerce (unsafeCoerce)

-- | A handle for inter-process communication (IPC).
foreign import data Handle :: Type

-- | Opaque type returned by `spawn`, `fork` and `exec`.
-- | Needed as input for most methods in this module.
-- |
-- | `ChildProcess` extends `EventEmitter`
newtype ChildProcess = ChildProcess ChildProcessRec

toEventEmitter :: ChildProcess -> EventEmitter
toEventEmitter = unsafeCoerce

closeH :: EventHandle ChildProcess (Exit -> Effect Unit) (EffectFn2 (Nullable Int) (Nullable String) Unit)
closeH = EventHandle "close" \cb -> mkEffectFn2 \code signal ->
  case toMaybe code, toMaybe signal >>= Signal.fromString of
    Just c, _ -> cb $ Normally c
    _, Just s -> cb $ BySignal s
    _, _ -> unsafeCrashWith $ "Impossible. 'close' event did not get an exit code or kill signal: " <> show code <> "; " <> show signal

disconnectH :: EventHandle0 ChildProcess
disconnectH = EventHandle "disconnect" identity

errorH :: EventHandle1 ChildProcess SystemError
errorH = EventHandle "error" mkEffectFn1

exitH :: EventHandle ChildProcess (Exit -> Effect Unit) (EffectFn2 (Nullable Int) (Nullable String) Unit)
exitH = EventHandle "exitH" \cb -> mkEffectFn2 \code signal ->
  case toMaybe code, toMaybe signal >>= Signal.fromString of
    Just c, _ -> cb $ Normally c
    _, Just s -> cb $ BySignal s
    _, _ -> unsafeCrashWith $ "Impossible. 'exit' event did not get an exit code or kill signal: " <> show code <> "; " <> show signal

messageH :: EventHandle ChildProcess (Foreign -> Maybe Handle -> Effect Unit) (EffectFn2 Foreign (Nullable Handle) Unit)
messageH = EventHandle "message" \cb -> mkEffectFn2 \a b -> cb a $ toMaybe b

spawnH :: EventHandle0 ChildProcess
spawnH = EventHandle "spawn" identity

runChildProcess :: ChildProcess -> ChildProcessRec
runChildProcess (ChildProcess r) = r

-- | Note: some of these types are lies, and so it is unsafe to access some of
-- | these record fields directly.
type ChildProcessRec =
  { stdin :: Nullable (Writable ())
  , stdout :: Nullable (Readable ())
  , stderr :: Nullable (Readable ())
  , pid :: Pid
  , connected :: Boolean
  , kill :: String -> Unit
  , send :: forall r. Fn2 { | r } Handle Boolean
  , disconnect :: Effect Unit
  }

-- | The standard input stream of a child process. Note that this is only
-- | available if the process was spawned with the stdin option set to "pipe".
stdin :: ChildProcess -> Writable ()
stdin = unsafeFromNullable (missingStream "stdin") <<< _.stdin <<< runChildProcess

-- | The standard output stream of a child process. Note that this is only
-- | available if the process was spawned with the stdout option set to "pipe".
stdout :: ChildProcess -> Readable ()
stdout = unsafeFromNullable (missingStream "stdout") <<< _.stdout <<< runChildProcess

-- | The standard error stream of a child process. Note that this is only
-- | available if the process was spawned with the stderr option set to "pipe".
stderr :: ChildProcess -> Readable ()
stderr = unsafeFromNullable (missingStream "stderr") <<< _.stderr <<< runChildProcess

missingStream :: String -> String
missingStream str =
  "Node.ChildProcess: stream not available: " <> str <> "\nThis is probably "
    <> "because you passed something other than Pipe to the stdio option when "
    <> "you spawned it."

foreign import unsafeFromNullable :: forall a. String -> Nullable a -> a

-- | The process ID of a child process. Note that if the process has already
-- | exited, another process may have taken the same ID, so be careful!
pid :: ChildProcess -> Effect (Maybe Pid)
pid cp = map toMaybe $ runEffectFn1 pidImpl cp

foreign import pidImpl :: EffectFn1 (ChildProcess) (Nullable Pid)

-- | Indicates whether it is still possible to send and receive
-- | messages from the child process.
connected :: ChildProcess -> Effect Boolean
connected cp = runEffectFn1 connectedImpl cp

foreign import connectedImpl :: EffectFn1 (ChildProcess) (Boolean)

exitCode :: ChildProcess -> Effect (Maybe Int)
exitCode cp = map toMaybe $ runEffectFn1 exitCodeImpl cp

foreign import exitCodeImpl :: EffectFn1 (ChildProcess) (Nullable Int)

-- | Send messages to the (`nodejs`) child process.
-- |
-- | See the [node documentation](https://nodejs.org/api/child_process.html#child_process_subprocess_send_message_sendhandle_options_callback)
-- | for in-depth documentation.
send
  :: forall props
   . { | props }
  -> Handle
  -> ChildProcess
  -> Effect Boolean
send msg handle (ChildProcess cp) = mkEffect \_ -> runFn2 cp.send msg handle

-- | Closes the IPC channel between parent and child.
disconnect :: ChildProcess -> Effect Unit
disconnect cp = runEffectFn1 disconnectImpl cp

foreign import disconnectImpl :: EffectFn1 (ChildProcess) (Unit)

kill :: ChildProcess -> Effect Boolean
kill cp = runEffectFn1 killImpl cp

foreign import killImpl :: EffectFn1 (ChildProcess) (Boolean)

kill' :: String -> ChildProcess -> Effect Boolean
kill' sig cp = runEffectFn2 killStrImpl cp sig

foreign import killStrImpl :: EffectFn2 (ChildProcess) (String) (Boolean)

-- | Send a signal to a child process. In the same way as the
-- | [unix kill(2) system call](https://linux.die.net/man/2/kill),
-- | sending a signal to a child process won't necessarily kill it.
-- |
-- | The resulting effects of this function depend on the process
-- | and the signal. They can vary from system to system.
-- | The child process might emit an `"error"` event if the signal
-- | could not be delivered.
killSignal :: Signal -> ChildProcess -> Effect Boolean
killSignal sig cp = kill' (Signal.toString sig) cp

killed :: ChildProcess -> Effect Boolean
killed cp = runEffectFn1 killedImpl cp

signalCode :: ChildProcess -> Effect (Maybe String)
signalCode cp = map toMaybe $ runEffectFn1 signalCodeImpl cp

foreign import signalCodeImpl :: EffectFn1 (ChildProcess) (Nullable String)

foreign import killedImpl :: EffectFn1 (ChildProcess) (Boolean)

foreign import spawnArgs :: ChildProcess -> Array String

foreign import spawnFile :: ChildProcess -> String

mkEffect :: forall a. (Unit -> a) -> Effect a
mkEffect = unsafeCoerce

-- | Specifies how a child process exited; normally (with an exit code), or
-- | due to a signal.
data Exit
  = Normally Int
  | BySignal Signal

instance showExit :: Show Exit where
  show (Normally x) = "Normally " <> show x
  show (BySignal sig) = "BySignal " <> show sig

-- | Spawn a child process. Note that, in the event that a child process could
-- | not be spawned (for example, if the executable was not found) this will
-- | not throw an error. Instead, the `ChildProcess` will be created anyway,
-- | but it will immediately emit an 'error' event.
spawn
  :: String
  -> Array String
  -> SpawnOptions
  -> Effect ChildProcess
spawn cmd args = spawnImpl cmd args <<< convertOpts
  where
  convertOpts opts =
    { cwd: fromMaybe undefined opts.cwd
    , stdio: toActualStdIOOptions opts.stdio
    , env: toNullable opts.env
    , detached: opts.detached
    , uid: fromMaybe undefined opts.uid
    , gid: fromMaybe undefined opts.gid
    }

foreign import spawnImpl
  :: forall opts
   . String
  -> Array String
  -> { | opts }
  -> Effect ChildProcess

-- There's gotta be a better way.
foreign import undefined :: forall a. a

-- | Configuration of `spawn`. Fields set to `Nothing` will use
-- | the node defaults.
type SpawnOptions =
  { cwd :: Maybe String
  , stdio :: Array (Maybe StdIOBehaviour)
  , env :: Maybe (Object String)
  , detached :: Boolean
  , uid :: Maybe Uid
  , gid :: Maybe Gid
  }

-- | A default set of `SpawnOptions`. Everything is set to `Nothing`,
-- | `detached` is `false` and `stdio` is `ChildProcess.pipe`.
defaultSpawnOptions :: SpawnOptions
defaultSpawnOptions =
  { cwd: Nothing
  , stdio: pipe
  , env: Nothing
  , detached: false
  , uid: Nothing
  , gid: Nothing
  }

-- | Similar to `spawn`, except that this variant will:
-- | * run the given command with the shell,
-- | * buffer output, and wait until the process has exited before calling the
-- |   callback.
-- |
-- | Note that the child process will be killed if the amount of output exceeds
-- | a certain threshold (the default is defined by Node.js).
exec
  :: String
  -> ExecOptions
  -> (ExecResult -> Effect Unit)
  -> Effect ChildProcess
exec cmd opts callback =
  execImpl cmd (convertExecOptions opts) \err stdout' stderr' ->
    callback
      { error: toMaybe err
      , stdout: stdout'
      , stderr: stderr'
      }

foreign import execImpl
  :: String
  -> ActualExecOptions
  -> (Nullable Exception.Error -> Buffer -> Buffer -> Effect Unit)
  -> Effect ChildProcess

-- | Like `exec`, except instead of using a shell, it passes the arguments
-- | directly to the specified command.
execFile
  :: String
  -> Array String
  -> ExecOptions
  -> (ExecResult -> Effect Unit)
  -> Effect ChildProcess
execFile cmd args opts callback =
  execFileImpl cmd args (convertExecOptions opts) \err stdout' stderr' ->
    callback
      { error: toMaybe err
      , stdout: stdout'
      , stderr: stderr'
      }

foreign import execFileImpl
  :: String
  -> Array String
  -> ActualExecOptions
  -> (Nullable Exception.Error -> Buffer -> Buffer -> Effect Unit)
  -> Effect ChildProcess

foreign import data ActualExecOptions :: Type

convertExecOptions :: ExecOptions -> ActualExecOptions
convertExecOptions opts = unsafeCoerce
  { cwd: fromMaybe undefined opts.cwd
  , env: fromMaybe undefined opts.env
  , encoding: maybe undefined encodingToNode opts.encoding
  , shell: fromMaybe undefined opts.shell
  , timeout: fromMaybe undefined opts.timeout
  , maxBuffer: fromMaybe undefined opts.maxBuffer
  , killSignal: fromMaybe undefined opts.killSignal
  , uid: fromMaybe undefined opts.uid
  , gid: fromMaybe undefined opts.gid
  }

-- | Configuration of `exec`. Fields set to `Nothing`
-- | will use the node defaults.
type ExecOptions =
  { cwd :: Maybe String
  , env :: Maybe (Object String)
  , encoding :: Maybe Encoding
  , shell :: Maybe String
  , timeout :: Maybe Number
  , maxBuffer :: Maybe Int
  , killSignal :: Maybe Signal
  , uid :: Maybe Uid
  , gid :: Maybe Gid
  }

-- | A default set of `ExecOptions`. Everything is set to `Nothing`.
defaultExecOptions :: ExecOptions
defaultExecOptions =
  { cwd: Nothing
  , env: Nothing
  , encoding: Nothing
  , shell: Nothing
  , timeout: Nothing
  , maxBuffer: Nothing
  , killSignal: Nothing
  , uid: Nothing
  , gid: Nothing
  }

-- | The combined output of a process calld with `exec`.
type ExecResult =
  { stderr :: Buffer
  , stdout :: Buffer
  , error :: Maybe Exception.Error
  }

-- | Generally identical to `exec`, with the exception that
-- | the method will not return until the child process has fully closed.
-- | Returns: The stdout from the command.
execSync
  :: String
  -> ExecSyncOptions
  -> Effect Buffer
execSync cmd opts =
  execSyncImpl cmd (convertExecSyncOptions opts)

foreign import execSyncImpl
  :: String
  -> ActualExecSyncOptions
  -> Effect Buffer

-- | Generally identical to `execFile`, with the exception that
-- | the method will not return until the child process has fully closed.
-- | Returns: The stdout from the command.
execFileSync
  :: String
  -> Array String
  -> ExecSyncOptions
  -> Effect Buffer
execFileSync cmd args opts =
  execFileSyncImpl cmd args (convertExecSyncOptions opts)

foreign import execFileSyncImpl
  :: String
  -> Array String
  -> ActualExecSyncOptions
  -> Effect Buffer

foreign import data ActualExecSyncOptions :: Type

convertExecSyncOptions :: ExecSyncOptions -> ActualExecSyncOptions
convertExecSyncOptions opts = unsafeCoerce
  { cwd: fromMaybe undefined opts.cwd
  , input: fromMaybe undefined opts.input
  , stdio: toActualStdIOOptions opts.stdio
  , env: fromMaybe undefined opts.env
  , timeout: fromMaybe undefined opts.timeout
  , maxBuffer: fromMaybe undefined opts.maxBuffer
  , killSignal: fromMaybe undefined opts.killSignal
  , uid: fromMaybe undefined opts.uid
  , gid: fromMaybe undefined opts.gid
  }

type ExecSyncOptions =
  { cwd :: Maybe String
  , input :: Maybe String
  , stdio :: Array (Maybe StdIOBehaviour)
  , env :: Maybe (Object String)
  , timeout :: Maybe Number
  , maxBuffer :: Maybe Int
  , killSignal :: Maybe Signal
  , uid :: Maybe Uid
  , gid :: Maybe Gid
  }

defaultExecSyncOptions :: ExecSyncOptions
defaultExecSyncOptions =
  { cwd: Nothing
  , input: Nothing
  , stdio: pipe
  , env: Nothing
  , timeout: Nothing
  , maxBuffer: Nothing
  , killSignal: Nothing
  , uid: Nothing
  , gid: Nothing
  }

-- | A special case of `spawn` for creating Node.js child processes. The first
-- | argument is the module to be run, and the second is the argv (command line
-- | arguments).
foreign import fork
  :: String
  -> Array String
  -> Effect ChildProcess

-- | Behaviour for standard IO streams (eg, standard input, standard output) of
-- | a child process.
-- |
-- | * `Pipe`: creates a pipe between the child and parent process, which can
-- |   then be accessed as a `Stream` via the `stdin`, `stdout`, or `stderr`
-- |   functions.
-- | * `Ignore`: ignore this stream. This will cause Node to open /dev/null and
-- |   connect it to the stream.
-- | * `ShareStream`: Connect the supplied stream to the corresponding file
-- |    descriptor in the child.
-- | * `ShareFD`: Connect the supplied file descriptor (which should be open
-- |   in the parent) to the corresponding file descriptor in the child.
data StdIOBehaviour
  = Pipe
  | Ignore
  | ShareStream (forall r. Stream r)
  | ShareFD FS.FileDescriptor

-- | Create pipes for each of the three standard IO streams.
pipe :: Array (Maybe StdIOBehaviour)
pipe = map Just [ Pipe, Pipe, Pipe ]

-- | Share `stdin` with `stdin`, `stdout` with `stdout`,
-- | and `stderr` with `stderr`.
inherit :: Array (Maybe StdIOBehaviour)
inherit = map Just
  [ ShareStream process.stdin
  , ShareStream process.stdout
  , ShareStream process.stderr
  ]

foreign import process :: forall props. { | props }

-- | Ignore all streams.
ignore :: Array (Maybe StdIOBehaviour)
ignore = map Just [ Ignore, Ignore, Ignore ]

-- Helpers

foreign import data ActualStdIOBehaviour :: Type

toActualStdIOBehaviour :: StdIOBehaviour -> ActualStdIOBehaviour
toActualStdIOBehaviour b = case b of
  Pipe -> c "pipe"
  Ignore -> c "ignore"
  ShareFD x -> c x
  ShareStream stream -> c stream
  where
  c :: forall a. a -> ActualStdIOBehaviour
  c = unsafeCoerce

type ActualStdIOOptions = Array (Nullable ActualStdIOBehaviour)

toActualStdIOOptions :: Array (Maybe StdIOBehaviour) -> ActualStdIOOptions
toActualStdIOOptions = map (toNullable <<< map toActualStdIOBehaviour)
