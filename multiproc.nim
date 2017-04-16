# vim: sw=2 ts=2 sts=2 tw=80 et:
from "msgpack4nim/msgpack4nim" as msgpack import nil
from asyncdispatch import nil
import asyncdispatch
from streams import nil
from posix import nil
from os import nil

# http://beej.us/guide/bgipc/output/html/singlepage/bgipc.html
posix.signal(posix.SIGCHLD, posix.SIG_IGN) # Do not wait() for childs.
#var sid = posix.setsid() # This could prevent us from hearing Ctrl-C, but makes
#all sub-procs killable via 'kill -PID'


type
  Fork = ref object
    pid: int
    pipe_child2parent_rw: array[0..1, cint]
    pipe_parent2child_rw: array[0..1, cint]
  Pool = ref object
    forks*: seq[Fork]
#type
  #RpcFork[TArg,TResult] = ref object
  #  pid: int
  #  pipe_ends: array[0..1, cint]
  #RpcPool[TArg,TResult] = ref object
  #  forks: seq[RpcFork[TArg,TResult]]

proc err(msg: string) =
    raise newException(OSError, $posix.strerror(posix.errno) & ":" & msg)
proc prepareChild(fork: Fork) =
  # We are in the child.
  #posix.signal(posix.SIGINT, posix.SIG_DFL)
  #while true:
  #  os.sleep(1000)
  #posix.onSignal(posix.SIGINT):
  #  echo "Received SIGINT" & $posix.getpid()
  #  discard posix.kill(posix.getpid(), posix.SIGINT)
  #  system.quit(system.QuitFailure)
  posix.onSignal(posix.SIGTERM):
    echo "Received SIGTERM" & $posix.getpid()
    #discard posix.kill(posix.getpid(), posix.SIGINT)
    system.quit(system.QuitSuccess)
proc newFork(): Fork =
  new(result)
  block:
    let ret = posix.pipe(result.pipe_child2parent_rw)
    assert ret == 0
  block:
    let ret = posix.pipe(result.pipe_parent2child_rw)
    assert ret == 0
  var pid = posix.fork()
  let word = "helloo"
  if pid == 0:
    echo "In child"
    discard posix.close(result.pipe_child2parent_rw[0]) # read end
    prepareChild(result)
    let ret = posix.write(result.pipe_child2parent_rw[1], cstring(word), len(word))
    assert ret == len(word)
  elif pid > 0:
    echo "Parent forked:", pid
    result.pid = pid
    discard posix.close(result.pipe_child2parent_rw[1]) # write end
    #while true:
    #  os.sleep(1000)
    #system.quit(system.QuitSuccess)
    var myword = newStringOfCap(len(word))
    myword.setLen(len(word))
    let ret = posix.read(result.pipe_child2parent_rw[0], cstring(myword), len(myword))
    echo "myword:", myword
    assert ret == len(myword)
  else:
    err("fork() failed:" & $pid)
proc newPool*(n: int): Pool =
  new(result)
  newSeq(result.forks, n)
  for i in 0..<n:
    result.forks[i] = newFork()
################
proc readAll(fd: cint, start: pointer, nbytes: int) =
  # Either read nbytes, or raiseOsError.
  var ret: int
  var bytesSoFar: int = 0
  var current: ByteAddress = cast[ByteAddress](start)
  while bytesSoFar < nbytes:
    ret = posix.read(fd, cast[pointer](current), nbytes)
    if ret > 0:
      bytesSoFar += ret
      current = current +% ret
    elif ret == 0:
      os.raiseOsError("In readAll(), fd was closed.")
    else:
      os.raiseOsError(os.OsErrorCode(posix.errno), "In readAll(), ret < 0") # TODO: format
proc writeAll(fd: cint, start: pointer, nbytes: int) =
  # Either write nbytes, or raiseOsError.
  var ret: int
  var bytesSoFar: int = 0
  var current: ByteAddress = cast[ByteAddress](start)
  while bytesSoFar < nbytes:
    ret = posix.write(fd, cast[pointer](current), nbytes)
    if ret > 0:
      bytesSoFar += ret
      current = current +% ret
    elif ret == 0:
      os.raiseOsError("In writeAll(), fd was closed.")
    else:
      os.raiseOsError(os.OsErrorCode(posix.errno), "In writeAll(), ret < 0") # TODO: format
proc runChild[TArg,TResult](fork: Fork, f: proc(arg: TArg): TResult) =
  # We are in the child.
  #posix.signal(posix.SIGINT, posix.SIG_DFL)
  #  os.sleep(1000)
  var ret: int
  var msg_len: int
  var msg = newString(0)
  while true:
    # recv
    readAll(fork.pipe_parent2child_rw[0], addr msg_len, 8)
    assert sizeof(msg_len) == 8
    msg.setLen(msg_len) # I think this avoids zeroing the string first.
    echo "child recving msg_len=", msg_len
    readAll(fork.pipe_parent2child_rw[0], cstring(msg), msg_len)
    #var s = streams.newStringStream()
    #s.writeData(cstring(msg), msg_len)
    var call_arg: TArg
    msgpack.unpack(msg, call_arg)
    echo "child call_arg=", call_arg
    var call_result = f(call_arg)
    echo "child call_result=", call_result
    #s.setPosition(0)
    # send
    msg = msgpack.pack(call_result)
    msg_len = len(msg)
    writeAll(fork.pipe_child2parent_rw[1], addr msg_len, 8)
    echo "child sending msg_len=", msg_len
    writeAll(fork.pipe_child2parent_rw[1], cstring(msg), msg_len)
proc runParent*[TArg,TResult](fork: Fork, arg: TArg): Future[TResult] {.async.} =
  #var retFuture = asyncdispatch.newFuture[TResult]("multiproc.runParent")
  # We are in the child.
  #posix.signal(posix.SIGINT, posix.SIG_DFL)
  #var ret: int
  var msg_len: int
  var msg: string
  # send
  msg = msgpack.pack(arg)
  msg_len = len(msg)
  writeAll(fork.pipe_parent2child_rw[1], addr msg_len, 8)
  echo "parent sending msg_len=", msg_len
  writeAll(fork.pipe_parent2child_rw[1], cstring(msg), msg_len)
  # recv
  readAll(fork.pipe_child2parent_rw[0], addr msg_len, 8)
  assert sizeof(msg_len) == 8
  msg.setLen(msg_len) # I think this avoids zeroing the string first.
  echo "parent recving msg_len=", msg_len
  readAll(fork.pipe_child2parent_rw[0], cstring(msg), msg_len)
  #var call_result: TResult
  #msgpack.unpack(msg, call_result)
  msgpack.unpack(msg, result)
  #asyncdispatch.complete(retFuture, call_result)
  #return retFuture
proc newRpcFork[TArg,TResult](f: proc(arg: TArg): TResult): Fork =
  new(result)
  block:
    let ret = posix.pipe(result.pipe_child2parent_rw)
    assert ret == 0
  block:
    let ret = posix.pipe(result.pipe_parent2child_rw)
    assert ret == 0
  var pid = posix.fork()
  let word = "helloo"
  if pid == 0:
    echo "In child"
    discard posix.close(result.pipe_child2parent_rw[0]) # read end
    discard posix.close(result.pipe_parent2child_rw[1]) # write end
    prepareChild(result)
    runChild[TArg,TResult](result, f)
    system.quit(system.QuitFailure)
  elif pid > 0:
    echo "Parent forked:", pid
    result.pid = pid
    discard posix.close(result.pipe_parent2child_rw[0]) # read end
    discard posix.close(result.pipe_child2parent_rw[1]) # write end
    #var call_result = runParent[TArg,TResult](result, 7)
    #echo "from child:", call_result
  else:
    err("fork() failed:" & $pid)
proc newRpcPool*[TArg,TResult](n: int, f: proc(arg: TArg): TResult): Pool =
  new(result)
  newSeq(result.forks, n)
  for i in 0..<n:
    echo "i=", i
    result.forks[i] = newRpcFork[TArg,TResult](f)
proc closePool*(pool: Pool) =
  echo "closing pool"
  for i in 0..<len(pool.forks):
    echo "finished newRpcFork for i=", i
    discard posix.kill(pool.forks[i].pid, posix.SIGTERM)
proc apply_async*[TArg,TResult](pool: Pool, f: proc(arg: TArg): TResult, arg: TArg): TResult =
  var s = streams.newStringStream()
  echo "ser..."
  msgpack.pack(s, arg)

  streams.setPosition(s, 0)
  echo "deser..."
  var argP: TArg
  msgpack.unpack(s, argP)
  return f(argP)
