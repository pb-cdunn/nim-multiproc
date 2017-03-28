# vim: sw=2 ts=2 sts=2 tw=80 et:
import multiproc

proc go() =
  echo "hello"
proc main() =
  echo "hi"
  var pool = multiproc.newPool(1)

main()
