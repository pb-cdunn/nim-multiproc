# vim: sw=2 ts=2 sts=2 tw=80 et:
from "msgpack4nim/msgpack4nim" as msgpack import nil
from streams import nil
from posix import nil

# http://beej.us/guide/bgipc/output/html/singlepage/bgipc.html
posix.signal(posix.SIGCHLD, posix.SIGIGN) # Do not wait() for childs.

type
  Fork = ref object
    pid: int
  Pool = ref object
    forks: seq[Fork]

proc err(msg: string) =
    raise newException(OSError, $posix.strerror(posix.errno) & ":" & msg)
proc prepareChild(fork: var Fork) =
  # We are in the child.
  posix.signal(posix.SIGINT, posix.SIG_DFL)
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
  else:
    err("fork() failed:" & $pid)
proc newPool*(n: int): Pool =
  new(result)
  newSeq(result.forks, n)
  for i in 0..<n:
    result.forks[i] = newFork()
proc apply_async*[TArg](pool: Pool, f: proc(arg: TArg), arg: TArg) =
  var s = streams.newStringStream()
  echo "ser..."
  msgpack.pack(s, arg)

  streams.setPosition(s, 0)
  echo "deser..."
  var argP: TArg
  msgpack.unpack(s, argP)
  f(argP)
