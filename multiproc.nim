# vim: sw=2 ts=2 sts=2 tw=0 et:
from "msgpack4nim/msgpack4nim" as msgpack import nil
from asyncdispatch import nil
import asyncdispatch
from streams import nil
from posix import nil
from os import nil

const debug = false

# http://beej.us/guide/bgipc/output/html/singlepage/bgipc.html
#posix.signal(posix.SIGCHLD, posix.SIG_IGN) # Do not wait() for childs.
#var sid = posix.setsid() # This could prevent us from hearing Ctrl-C, but makes
#all sub-procs killable via 'kill -PID'


type
  Fork = ref object
    pid: int
    pipe_child2parent_rw: array[0..1, cint]
    pipe_parent2child_rw: array[0..1, cint]
  Pool = ref object
    forks*: seq[Fork]

var gpid: int
var gpids: seq[int]
newSeq(gpids, 0)

proc log(msg: string) =
  stderr.write("[" & $gpid & "]" & msg & "\L")
proc err(msg: string) =
    raise newException(OSError, $posix.strerror(posix.errno) & ":" & msg)
#posix.onSignal(posix.SIGINT):
#  log("Received SIGINT in " & $posix.getpid())
#  for i in 0..<len(gpids):
#    let kpid = gpids[i]
#    log($i & ":" & $kpid & "Alive?" & $posix.kill(kpid, 0))
#    discard posix.kill(kpid, posix.SIGINT)
#    discard posix.kill(kpid, posix.SIGKILL)
#    #os.sleep(100)
#    log($i & ":" & $kpid & "Alive?" & $posix.kill(kpid, 0))
#  posix.signal(posix.SIGINT, posix.SIG_DFL)
#  discard posix.kill(gpid, posix.SIGINT)
#  #system.quit(system.QuitFailure)


proc setNonBlocking(fd: cint) {.inline.} =
  var x = posix.fcntl(fd, posix.F_GETFL, 0)
  if x == -1:
    os.raiseOSError(os.osLastError())
  else:
    var mode = x or posix.O_NONBLOCK
    if posix.fcntl(fd, posix.F_SETFL, mode) == -1:
      os.raiseOSError(os.osLastError())

proc prepareForDispatch(fd: cint) {.inline.} =
  log("prepareForDispatch (register and setNonBlocking) fd:" & $fd)
  setNonBlocking(fd)
  asyncdispatch.register(fd.AsyncFD)

proc close(fd: cint) =
  let ret = posix.close(fd)
  when debug:
    log(   "Closed:" & $fd)
  if ret != 0:
    os.raiseOsError(os.osLastError())

proc prepareChild(fork: Fork, other_fds: seq[cint]) =
  # We are in the child.
  when debug:
    posix.signal(posix.SIGINT, posix.SIG_DFL)
  #while true:
  #  os.sleep(1000)
  #posix.onSignal(posix.SIGINT):
  #  log("Received SIGINT" & $posix.getpid())
  #  discard posix.kill(posix.getpid(), posix.SIGINT)
  #  system.quit(system.QuitFailure)
  posix.onSignal(posix.SIGTERM):
    log("Received SIGTERM" & $posix.getpid())
    #discard posix.kill(posix.getpid(), posix.SIGINT)
    system.quit(system.QuitSuccess)
  when debug:
    log("In prepareChild()")
  #log(" -Closing fds:" & $fork.pipe_child2parent_rw[0] & " & " & $fork.pipe_parent2child_rw[1])
  #close(fork.pipe_child2parent_rw[0]) # read end
  #close(fork.pipe_parent2child_rw[1]) # write end
  when debug:
    log(" -Closing fds:" & $repr(other_fds))
  for i in 0..<len(other_fds):
    close(other_fds[i].cint)
  #prepareForDispatch(fork.pipe_child2parent_rw[1])
  prepareForDispatch(fork.pipe_parent2child_rw[0])

proc prepareParent(fork: Fork) =
  when debug:
    log("In prepareParent()")
    log(" Closing fds:" & $fork.pipe_child2parent_rw[1] & " & " & $fork.pipe_parent2child_rw[0])
  close(fork.pipe_parent2child_rw[0]) # read end
  close(fork.pipe_child2parent_rw[1]) # write end
  #prepareForDispatch(fork.pipe_parent2child_rw[1])
  prepareForDispatch(fork.pipe_child2parent_rw[0])
  gpids.add(fork.pid)

proc finishChild(fork: Fork) =
  #log("unregistering in Child...") # There is no point, but maybe we could try anyway?
  #asyncdispatch.unregister(fork.pipe_child2parent_rw[1].AsyncFD)
  asyncdispatch.unregister(fork.pipe_parent2child_rw[0].AsyncFD)
  close(fork.pipe_child2parent_rw[1]) # write end
  close(fork.pipe_parent2child_rw[0]) # read end
  when debug:
    log(" -Closed and unregistered fds:" & $fork.pipe_parent2child_rw[0] & " & " & $fork.pipe_child2parent_rw[1])

proc finishParent(fork: Fork) =
  when debug:
    log("unregistering in Parent...")
  #asyncdispatch.unregister(fork.pipe_parent2child_rw[1].AsyncFD)
  asyncdispatch.unregister(fork.pipe_child2parent_rw[0].AsyncFD)
  close(fork.pipe_parent2child_rw[1]) # write end
  close(fork.pipe_child2parent_rw[0]) # read end
  when debug:
    log(" Closed and unregistered fds:" & $fork.pipe_child2parent_rw[0] & " & " & $fork.pipe_parent2child_rw[1])

proc readAll(fd: cint, start: pointer, nbytes: int): Future[void] =
  var retFuture = asyncdispatch.newFuture[void]("multiproc.readAll")
  var bytesSoFar: int = 0
  var current: ByteAddress = cast[ByteAddress](start)

  proc cb(afd: asyncdispatch.AsyncFD): bool =
    # Either read nbytes, or raiseOsError.
    result = true # Tell dispatcher to stop calling this callback.

    while bytesSoFar < nbytes:
      var ret: int = posix.read(afd.cint, cast[pointer](current), nbytes-bytesSoFar)
      if ret > 0:
        bytesSoFar += ret
        current = current +% ret
        #log("Read " & $ret & " bytes. togo=" & $(nbytes-bytesSoFar))
      elif ret == 0:
        #os.raiseOsError(os.osLastError(), "In readAll(), fd was closed.")
        when debug:
          log("Read 0 bytes. Is that OK?") # TODO(CD): Remove.
        return
      else:
        let err = os.osLastError()
        #log("Error:" & os.osErrorMsg(err) & ":" & $err.int & ", result=" & $result & ", bytestogo=" & $(nbytes-bytesSoFar))
        if err.int32 != posix.EAGAIN:
          asyncdispatch.fail(retFuture, newException(OSError, "In readAll(), ret<0: " & os.osErrorMsg(err)))
          #result = true # We still want this callback to be called.
        else:
          result = false # We still want this callback to be called.
        return
    when debug:
      log("Completing retFuture " & $retFuture.id & ", bytesSoFar=" & $bytesSoFar)
      assert result
    asyncdispatch.complete(retFuture)

  if not cb(fd.AsyncFD):
    when debug:
      log("cb(" & $fd & ") returned false. Adding cb.")
    addRead(fd.AsyncFD, cb)
  when debug:
    log("Returning retFuture from readAll() - finished?" & $retFuture.id & $retFuture.finished)
  return retFuture

proc writeAll(fd: cint, start: pointer, nbytes: int) =
  # Either write nbytes, or raiseOsError.
  # Note: We could make this async, but it might not buy us much.
  var ret: int
  var bytesSoFar: int = 0
  var current: ByteAddress = cast[ByteAddress](start)
  while bytesSoFar < nbytes:
    when debug:
      log("togo:" & $(nbytes-bytesSoFar))
    ret = posix.write(fd, cast[pointer](current), nbytes-bytesSoFar)
    if ret > 0:
      bytesSoFar += ret
      current = current +% ret
    elif ret == 0:
      os.raiseOsError(os.osLastError(), "In writeAll(), fd was closed.")
    else:
      let err = os.osLastError()
      if err.int32 != posix.EAGAIN:
        os.raiseOsError(err, "In writeAll(), ret < 0") # TODO: format

proc runChild[TArg,TResult](fork: Fork, f: proc(arg: TArg): TResult) =
  # We are in the child.
  #posix.signal(posix.SIGINT, posix.SIG_DFL)
  #var ret: int
  var msg_len: int
  var msg = newString(0)
  while true:
    # recv
    try:
      when debug:
        log("child reading msg_len on " & $fork.pipe_parent2child_rw[0])
      waitFor readAll(fork.pipe_parent2child_rw[0], addr msg_len, 8)
      assert sizeof(msg_len) == 8
      msg.setLen(msg_len) # I think this avoids zeroing the string first.
      when debug:
        log("child recving msg of msg_len=" & $msg_len)
      if msg_len == 0:
        log("Child sending zero back")
        writeAll(fork.pipe_child2parent_rw[1], addr msg_len, 8)
        log("Shutting down child:" & $posix.getpid())
        finishChild(fork)
        system.quit(system.QuitFailure)
      waitFor readAll(fork.pipe_parent2child_rw[0], cstring(msg), msg_len)
      when debug:
        log("child read full msg on " & $fork.pipe_parent2child_rw[0])
    except OsError:
      log("trapped exception in runChild():" & getCurrentExceptionMsg())
      continue
    except:
      log("trapped unknown exception in runChild()")
      raise
    var call_arg: TArg
    msgpack.unpack(msg, call_arg)
    when debug:
      log("child call_arg=" & $call_arg)
    var call_result = f(call_arg)

    # send
    msg = msgpack.pack(call_result)
    msg_len = len(msg)
    when debug:
      log("child sending msg_len on" & $fork.pipe_child2parent_rw[1])
    writeAll(fork.pipe_child2parent_rw[1], addr msg_len, 8)
    when debug:
      log("child sending msg of msg_len=" & $msg_len)
    writeAll(fork.pipe_child2parent_rw[1], cstring(msg), msg_len)

proc sendZero(fork: Fork) =
  # By sending zero (64-bit), we let the child know we done.
  var msg_len: int = 0
  when debug:
    log("parent sendZero()")
  writeAll(fork.pipe_parent2child_rw[1], addr msg_len, 8)
  when debug:
    log("parent recv zero")
  waitFor readAll(fork.pipe_child2parent_rw[0], addr msg_len, 8)

proc runParent*[TArg,TResult](fork: Fork, arg: TArg): Future[TResult] {.async.} =
  var msg_len: int
  var msg: string

  # send
  msg = msgpack.pack(arg)
  msg_len = len(msg)
  when debug:
    log("parent sending msg_len on " & $fork.pipe_parent2child_rw[1])
  writeAll(fork.pipe_parent2child_rw[1], addr msg_len, 8)
  when debug:
    log("parent sending msg of msg_len=" & $msg_len)
  writeAll(fork.pipe_parent2child_rw[1], cstring(msg), msg_len)

  # recv
  when debug:
    log("parent reading msg_len on " & $fork.pipe_child2parent_rw[0])
  await readAll(fork.pipe_child2parent_rw[0], addr msg_len, 8)
  assert sizeof(msg_len) == 8
  msg.setLen(msg_len) # I think this avoids zeroing the string first.
  when debug:
    log("parent recving msg of msg_len=" & $msg_len)
  await readAll(fork.pipe_child2parent_rw[0], cstring(msg), msg_len)
  log("parent finished both await readAll()")
  #var call_result: TResult
  #msgpack.unpack(msg, call_result)
  msgpack.unpack(msg, result)
  #asyncdispatch.complete(retFuture, call_result)
  #return retFuture
  log("parent returning call_result")
  #return call_result

proc newRpcFork[TArg,TResult](f: proc(arg: TArg): TResult, other_fds: var seq[cint]): Fork =
  # We send other_fds so the child can close everything it does not need.
  new(result)
  block:
    let ret = posix.pipe(result.pipe_child2parent_rw)
    assert ret == 0
  block:
    let ret = posix.pipe(result.pipe_parent2child_rw)
    assert ret == 0
  other_fds.add(result.pipe_child2parent_rw[0])
  other_fds.add(result.pipe_parent2child_rw[1])
  var pid = posix.fork()
  gpid = posix.getpid().int
  if pid == 0:
    when debug:
      log("In child with pid:" & $posix.getpid())
    prepareChild(result, other_fds)
    runChild[TArg,TResult](result, f)
    system.quit(system.QuitFailure)
  elif pid > 0:
    other_fds.add(result.pipe_child2parent_rw[1])
    other_fds.add(result.pipe_parent2child_rw[0])
    when debug:
      log("Parent forked child with pid:" & $pid)
    result.pid = pid
  else:
    err("fork() failed:" & $pid)

proc newRpcPool*[TArg,TResult](n: int, f: proc(arg: TArg): TResult): Pool =
  new(result)
  newSeq(result.forks, n)
  var other_fds: seq[cint]
  newSeq(other_fds, 0)
  for i in 0..<n:
    log("i=" & $i)
    result.forks[i] = newRpcFork[TArg,TResult](f, other_fds)
  log("other_fds:" & repr(other_fds))
  for i in 0..<n:
    let fork = result.forks[i]
    log("prepareParent for i=" & $i)
    prepareParent(fork)

proc closePool*(pool: Pool) =
  # Remember to call this (in a finally block) or you will have dangling
  # children in some errors.
  log("closing Pool")
  for i in 0..<len(pool.forks):
    sendZero(pool.forks[i])
  for i in 0..<len(pool.forks):
    log("terminating newRpcFork for i=" & $i)
    let kpid = posix.Pid(pool.forks[i].pid)
    while posix.kill(kpid, 0) != 0:
      log("Waiting for " & $kpid & " to quit...")
      os.sleep(500)
    discard posix.kill(kpid, posix.SIGTERM)
  for i in 0..<len(pool.forks):
    let kpid = posix.Pid(pool.forks[i].pid)
    log("killing newRpcFork for i=" & $i)
    discard posix.kill(kpid, posix.SIGKILL)
  for i in 0..<len(pool.forks):
    log("finishing newRpcFork for i=" & $i)
    finishParent(pool.forks[i])
  while asyncdispatch.hasPendingOperations():
    log("Still pending...")
    try:
      asyncdispatch.poll(500)
    except ValueError:
      err(getCurrentExceptionMsg())
  log("No pending operations...")

proc apply_async*[TArg,TResult](pool: Pool, f: proc(arg: TArg): TResult, arg: TArg): TResult =
  var s = streams.newStringStream()
  log("ser...")
  msgpack.pack(s, arg)

  streams.setPosition(s, 0)
  log("deser...")
  var argP: TArg
  msgpack.unpack(s, argP)
  return f(argP)
