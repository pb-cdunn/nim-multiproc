# vim: sw=2 ts=2 sts=2 tw=80 et:
from asyncdispatch import nil
from strutils import nil
import multiproc
import asyncdispatch
from posix import nil

const resettable = false

proc square(x: int): int =
  echo "hello:", x
  return x*x

proc example0() =
  var fds: array[0..1, cint]
  let ret = posix.pipe(fds)
  echo "b4"
  asyncdispatch.register(fds[0].AsyncFD)
  proc cb(afd: asyncdispatch.AsyncFD): bool =
    echo "Hellooo"
  asyncdispatch.addRead(fds[0].AsyncFD, cb)
  echo "polling..."
  asyncdispatch.poll()
  echo "polled"
  asyncdispatch.unregister(fds[0].AsyncFD)
  #asyncdispatch.poll()
  echo "aft"
  when resettable:
    asyncdispatch.setGlobalDispatcher(nil)
  echo "aft2"
proc example1() =
  #asyncdispatch.setGlobalDispatcher(asyncdispatch.newDispatcher())
  when resettable:
    asyncdispatch.setGlobalDispatcher(nil)
  var rpool = multiproc.newRpcPool[int,int](1, square)
  try:
    var call_result = multiproc.runParent[int,int](rpool.forks[0], 7)
    echo "Final from child:", asyncdispatch.waitFor call_result
  finally:
    rpool.closePool()

proc big(x: int): string =
  echo "big hello:", x
  return strutils.repeat("Big", x)

proc example2() =
  var rpool = multiproc.newRpcPool[int,string](1, big)
  try:
    var call_result = multiproc.runParent[int,string](rpool.forks[0], 10_000_000)
    echo "Final from child: len=", len(asyncdispatch.waitFor call_result)
  finally:
    rpool.closePool()

proc example3() =
  echo "example 3"
  when resettable:
    #asyncdispatch.setGlobalDispatcher(asyncdispatch.newDispatcher())
    asyncdispatch.setGlobalDispatcher(nil)
  const n = 2
  var rpool = multiproc.newRpcPool[int,string](n, big)
  var results: seq[asyncdispatch.Future[string]]
  newSeq(results, n)
  try:
    for i in 0..<n:
      var call_result = multiproc.runParent[int,string](rpool.forks[i], 10_000_000)
      results[i] = call_result
    for j in 0..<n:
      let i = n - 1 - j
      echo "waitFor result[", i, "]:", results[i].finished
      let length = len(asyncdispatch.waitFor results[i])
      echo "Final from child " & $i & ": len=" & $length
  finally:
    rpool.closePool()

proc example4() =
  discard
  #var pool = multiproc.newPool(1)
  #var result = pool.apply_async(go, 1)
  #echo "result:", $result

proc main() =
  echo "hi"
  example0()
  example1()
  #example2()
  example3()
  #example4()
  echo "bye"

main()
