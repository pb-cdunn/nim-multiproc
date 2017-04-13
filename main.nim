# vim: sw=2 ts=2 sts=2 tw=80 et:
import multiproc
from asyncdispatch import nil

proc go(x: int): int =
  echo "hello:", x
  return x*x
proc main() =
  echo "hi"
  #var pool = multiproc.newPool(1)
  #var result = pool.apply_async(go, 1)
  #echo "result:", $result

  var rpool = multiproc.newRpcPool[int,int](1, go)
  var call_result = multiproc.runParent[int,int](rpool.forks[0], 7)
  echo "from child:", asyncdispatch.waitFor call_result
  rpool.closePool()

main()
