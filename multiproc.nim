# vim: sw=2 ts=2 sts=2 tw=80 et:
from "msgpack4nim/msgpack4nim" as msgpack import nil
from streams import nil
from posix import nil
from os import nil

# http://beej.us/guide/bgipc/output/html/singlepage/bgipc.html
posix.signal(posix.SIGCHLD, posix.SIGIGN) # Do not wait() for childs.
#var sid = posix.setsid() # This could prevent us from hearing Ctrl-C, but makes
#all sub-procs killable via 'kill -PID'

posix.onSignal(posix.SIGINT):
  echo "Received SIGINT" & $posix.getpid()
  discard posix.kill(posix.getpid(), posix.SIGINT)
  system.quit(system.QuitFailure)

type
  Fork = ref object
    pid: int
  Pool = ref object
    forks: seq[Fork]

proc err(msg: string) =
    raise newException(OSError, $posix.strerror(posix.errno) & ":" & msg)
proc prepareChild(fork: var Fork) =
  # We are in the child.
  #posix.signal(posix.SIGINT, posix.SIG_DFL)
  while true:
    os.sleep(1000)
  system.quit(system.QuitSuccess)
proc newFork(): Fork =
  new(result)
  var pid = posix.fork()
  if pid == 0:
    echo "In child"
    prepareChild(result)
  elif pid > 0:
    echo "Parent forked:", pid
    result.pid = pid
    #while true:
    #  os.sleep(1000)
    #system.quit(system.QuitSuccess)
  else:
    err("fork() failed:" & $pid)
proc newPool*(n: int): Pool =
  new(result)
  newSeq(result.forks, n)
  for i in 0..<n:
    result.forks[i] = newFork()
proc apply_async*[TArg,TResult](pool: Pool, f: proc(arg: TArg): TResult, arg: TArg): TResult =
  var s = streams.newStringStream()
  echo "ser..."
  msgpack.pack(s, arg)

  streams.setPosition(s, 0)
  echo "deser..."
  var argP: TArg
  msgpack.unpack(s, argP)
  return f(argP)
