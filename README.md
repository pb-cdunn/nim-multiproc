## Running

    git submodule update --init
    make

## Result
```
Traceback (most recent call last)
main.nim(61)             main
main.nim(57)             main
main.nim(42)             example3
asyncdispatch.nim(1081)  waitFor
asyncdispatch.nim(1088)  poll
selectors.nim(173)       select
tables.nim(151)          []
Error: unhandled exception: key not found: 6 [KeyError]
```
Even though, in theory, fd=6 has already been unregistered in the Parent process.
