# vim: sw=2 ts=2 sts=2 tw=80 et:
import multiproc
import asyncdispatch

proc go(x: int): int =
  echo "hello:", x
  return 42
proc main() =
  echo "hi"
  var pool = multiproc.newPool(1)
  var result = pool.apply_async(go, 1)
  echo "result:", $result

main()
