# vim: sw=2 ts=2 sts=2 tw=80 et:
import multiproc

proc go(x: int) =
  echo "hello:", x
proc main() =
  echo "hi"
  var pool = multiproc.newPool(1)
  pool.apply_async(go, 1)

main()
