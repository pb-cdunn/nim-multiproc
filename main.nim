# vim: sw=2 ts=2 sts=2 tw=80 et:
from asyncdispatch import nil
from strutils import nil
import multiproc
import asyncdispatch

proc go(x: int): int =
  echo "hello:", x
  return x*x
proc big(x: int): string =
  echo "big hello:", x
  return strutils.repeat("Big", x)
proc main() =
  echo "hi"
  #var pool = multiproc.newPool(1)
  #var result = pool.apply_async(go, 1)
  #echo "result:", $result

  if false:
    var rpool = multiproc.newRpcPool[int,int](1, go)
    try:
      var call_result = multiproc.runParent[int,int](rpool.forks[0], 7)
      echo "Final from child:", asyncdispatch.waitFor call_result
    finally:
      rpool.closePool()
  if true:
    var rpool = multiproc.newRpcPool[int,string](1, big)
    try:
      var call_result = multiproc.runParent[int,string](rpool.forks[0], 10_000_000)
      echo "Final from child: len=", len(asyncdispatch.waitFor call_result)
    finally:
      rpool.closePool()

main()
