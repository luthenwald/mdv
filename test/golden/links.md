# Links

A [relative path](docs/manual.md), an [anchor](#section), a [scheme](https://example.org/path?q=1), a [bare host](example.org/no/scheme), [file](file:///etc/hosts), [mail](mailto:me@example.org), and a [javascript one](javascript:alert(1)).

An [empty destination]() and an [angle one](<with space.md>).

A [line break in the destination](a&#10;b) and a [tab](a&#9;b).

A [data URI](data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==) and an ![image with a data URI](data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7).

An autolink <https://example.org/auto>, an email <someone@example.org>, and <ftp://files.example.org>.

![an image](images/diagram.png "with a title") and ![another](https://example.org/i.png).

[a reference][ref], [another][REF] (case-insensitive), [a collapsed one][] and a [shortcut].

[ref]: https://example.org/reference "Title"
[a collapsed one]: ./here.md
[shortcut]: /absolute/path

A link whose text is **strong [with nested](https://example.org/inner) text** stays one link.

A long destination: [here](https://example.org/a/very/long/path/that/goes/on/and/on/past/the/end/of/the/line/to/see/how/the/shown/address/wraps).
