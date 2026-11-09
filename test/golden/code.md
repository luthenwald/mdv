# Code

```zig
const std = @import("std");

pub fn main() void {
	std.debug.print("a tab indents this line\n", .{});
    std.debug.print("and four spaces this one\n", .{});
}
```

```
a fence without a language, and a line long enough that it has to be hard-wrapped at every width we test here
```

~~~ruby startline=3 $%@#$
puts "info string with extra words, only the first shown"
~~~

```averyveryverylonglanguagenamethatcannotfitthenarrowmeasure
x
```

- A list item with code:

  ```c
  int main(void) { return 0; }
  ```

  and an indented block:

      indented, inside the item

1. Numbered, then code:

   ```
   second line is longer than the first by quite a bit, to wrap
   ```

An indented code block:

    first line
        deeper
    	a tab after four spaces

``````
a fence with six backticks holds
```
three inside
``````

```
an unclosed fence runs to the end of the document

with a blank line in it
