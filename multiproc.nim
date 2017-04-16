# vim: sw=2 ts=2 sts=2 tw=80 et:
from "msgpack4nim/msgpack4nim" as msgpack import nil
from asyncdispatch import nil
import asyncdispatch
from streams import nil
from posix import nil
from os import nil

const debug = false

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
    when debug:
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
proc readAll(fd: cint, start: pointer, nbytes: int): Future[void] =
  var retFuture = asyncdispatch.newFuture[void]("multiproc.readAll")
  var bytesSoFar: int = 0
  var current: ByteAddress = cast[ByteAddress](start)

  proc cb(afd: asyncdispatch.AsyncFD): bool =
    # Either read nbytes, or raiseOsError.
    result = true # Tell dispatcher to stop calling this callback.

    while bytesSoFar < nbytes:
      var ret: int = posix.read(afd.cint, cast[pointer](current), nbytes)
      if ret > 0:
        bytesSoFar += ret
        current = current +% ret
        #echo "Read " & $ret & " bytes. togo=" & $(nbytes-bytesSoFar)
      elif ret == 0:
        #os.raiseOsError("In readAll(), fd was closed.")
        when debug:
          echo "Read 0 bytes. Is that OK?" # TODO(CD): Remove.
        return
      else:
        let err = os.osLastError()
        #echo "Error:" & os.osErrorMsg(err) & ":" & $err.int & ", result=" & $result & ", bytestogo=" & $(nbytes-bytesSoFar)
        if err.int32 != posix.EAGAIN:
          asyncdispatch.fail(retFuture, newException(OSError, "In readAll(), ret<0: " & os.osErrorMsg(err)))
          #result = true # We still want this callback to be called.
        else:
          result = false # We still want this callback to be called.
        return
    when debug:
      echo "Completing retFuture, bytesSoFar=" & $bytesSoFar
    asyncdispatch.complete(retFuture)

  if not cb(fd.AsyncFD):
    addRead(fd.AsyncFD, cb)
  return retFuture

proc writeAll(fd: cint, start: pointer, nbytes: int) =
  # Either write nbytes, or raiseOsError.
  var ret: int
  var bytesSoFar: int = 0
  var current: ByteAddress = cast[ByteAddress](start)
  while bytesSoFar < nbytes:
    ret = posix.write(fd, cast[pointer](current), nbytes-bytesSoFar)
    if ret > 0:
      bytesSoFar += ret
      current = current +% ret
    elif ret == 0:
      os.raiseOsError("In writeAll(), fd was closed.")
    else:
      let err = os.osLastError()
      if err.int32 != posix.EAGAIN:
        os.raiseOsError(os.OsErrorCode(posix.errno), "In writeAll(), ret < 0") # TODO: format
proc injectStacktrace[T](future: Future[T]) =
  # TODO: Come up with something better.
  var msg = ""
  msg.add("\n  " & future.fromProc & "'s lead up to read of failed Future:")

  if not future.errorStackTrace.isNil and future.errorStackTrace != "":
    msg.add("\n" & future.errorStackTrace)
  else:
    msg.add("\n    Empty or nil stack trace.")
  future.error.msg.add(msg)
proc myasyncCheck*[T](future: Future[T]) =
  ## Sets a callback on `future` which raises an exception if the future
  ## finished with an error.
  ##
  ## This should be used instead of `discard` to discard void futures.
  echo "myasynccheck adds a callback."
  future.callback =
    proc () =
      echo "In myasynccheck cb, future.failed=" & $future.failed
      if future.failed:
        injectStacktrace(future)
        raise future.error
proc runChild[TArg,TResult](fork: Fork, f: proc(arg: TArg): TResult) =
  # We are in the child.
  #posix.signal(posix.SIGINT, posix.SIG_DFL)
  #  os.sleep(1000)
  var ret: int
  var msg_len: int
  var msg = newString(0)
  while true:
    # recv
    try:
      when debug:
        echo "child reading msg_len"
      waitFor readAll(fork.pipe_parent2child_rw[0], addr msg_len, 8)
      assert sizeof(msg_len) == 8
      msg.setLen(msg_len) # I think this avoids zeroing the string first.
      when debug:
        echo "child recving msg of msg_len=", msg_len
      waitFor readAll(fork.pipe_parent2child_rw[0], cstring(msg), msg_len)
    except OsError:
      when debug:
        echo "trapped exception in runChild():" & getCurrentExceptionMsg()
      continue
    except:
      when debug:
        echo "trapped unknown exception in runChild()"
      raise
    #var s = streams.newStringStream()
    #s.writeData(cstring(msg), msg_len)
    var call_arg: TArg
    msgpack.unpack(msg, call_arg)
    when debug:
      echo "child call_arg=", call_arg
    var call_result = f(call_arg)
    #echo "child call_result=", call_result
    #s.setPosition(0)
    # send
    msg = msgpack.pack(call_result)
    msg_len = len(msg)
    when debug:
      echo "child sending msg_len"
    writeAll(fork.pipe_child2parent_rw[1], addr msg_len, 8)
    when debug:
      echo "child sending msg of msg_len=", msg_len
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
  when debug:
    echo "parent sending msg_len"
  writeAll(fork.pipe_parent2child_rw[1], addr msg_len, 8)
  when debug:
    echo "parent sending msg of msg_len=", msg_len
  writeAll(fork.pipe_parent2child_rw[1], cstring(msg), msg_len)
  # recv
  when debug:
    echo "parent reading msg_len"
  await readAll(fork.pipe_child2parent_rw[0], addr msg_len, 8)
  assert sizeof(msg_len) == 8
  msg.setLen(msg_len) # I think this avoids zeroing the string first.
  when debug:
    echo "parent recving msg of msg_len=", msg_len
  await readAll(fork.pipe_child2parent_rw[0], cstring(msg), msg_len)
  var call_result: TResult
  msgpack.unpack(msg, call_result)
  #msgpack.unpack(msg, result)
  #asyncdispatch.complete(retFuture, call_result)
  #return retFuture
  return call_result
proc setNonBlocking(fd: cint) {.inline.} =
  var x = posix.fcntl(fd, posix.F_GETFL, 0)
  if x == -1:
    os.raiseOSError(os.osLastError())
  else:
    var mode = x or posix.O_NONBLOCK
    if posix.fcntl(fd, posix.F_SETFL, mode) == -1:
      os.raiseOSError(os.osLastError())
proc prepareForDispatch(fds: array[0..1, cint]) {.inline.} =
  setNonBlocking(fds[0])
  setNonBlocking(fds[1])
  asyncdispatch.register(fds[0].AsyncFD)
  asyncdispatch.register(fds[1].AsyncFD)
proc newRpcFork[TArg,TResult](f: proc(arg: TArg): TResult): Fork =
  new(result)
  block:
    let ret = posix.pipe(result.pipe_child2parent_rw)
    assert ret == 0
    prepareForDispatch(result.pipe_child2parent_rw)
  block:
    let ret = posix.pipe(result.pipe_parent2child_rw)
    assert ret == 0
    prepareForDispatch(result.pipe_parent2child_rw)
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
  # Remember to call this (in a finally block) or you will have dangling
  # children in some errors.
  echo "closing Pool"
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
