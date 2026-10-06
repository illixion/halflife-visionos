# Third-party licenses

Lambda VisionPro links the following MIT-licensed packages as local Swift
package dependencies (see [First-time setup](README.md#first-time-setup)).
Their own repos remain MIT-licensed; this notice satisfies MIT's
notice-inclusion requirement for the combined LambdaVision distribution.

## RAVESDK

<https://github.com/illixion/RAVESDK>

```
MIT License

Copyright (c) 2026 Illixion

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## RAVEEngine

<https://github.com/illixion/RAVEEngine>

```
MIT License

Copyright (c) 2026 Illixion

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## libarchive.js (bundled in the Wi-Fi management page)

<https://github.com/nika-begiashvili/libarchivejs> — version 2.0.2, MIT.
Its `dist/` files (`libarchive.js`, `worker-bundle.js`, `libarchive.wasm`)
are vendored unmodified in
`LambdaVision/Packages/GameLibrary/Sources/GameLibraryServer/Web/vendor/libarchive/`
and ship inside the app, served to the visitor's browser to unpack 7z and
RAR archives. The WebAssembly build contains libarchive 3.7.2 (BSD
2-Clause), zlib (zlib License), bzip2 1.0.6 (BSD-style), liblzma from XZ
Utils (public domain / 0BSD) and OpenSSL's crypto (Apache 2.0); the module
bundles Comlink (Apache 2.0). Every one of these notices is reproduced in
full in `vendor/libarchive/LICENSES.txt` next to the files, which is also
served with the page.
