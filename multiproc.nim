# vim: sw=2 ts=2 sts=2 tw=80 et:
from "msgpack4nim/msgpack4nim" as msgpack import nil
from streams import nil

type
  Fork = ref object
  Pool = ref object
    forks: seq[Fork]

proc newPool*(n: int): Pool =
  new(result)
  newSeq(result.forks, n)
proc apply_async*[TArg](pool: Pool, f: proc(arg: TArg), arg: TArg) =
  var s = streams.newStringStream()
  echo "ser..."
  msgpack.pack(s, arg)

  streams.setPosition(s, 0)
  echo "deser..."
  var argP: TArg
  msgpack.unpack(s, argP)
  f(argP)
