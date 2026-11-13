# Third-party notices

KVM Console is released under the MIT License (see `LICENSE`). Builds of the app include the software below, which is distributed under its own license. The same notice is bundled in the app as `Credits.rtf` and shown in **KVM Console > About KVM Console**; keep the two in step when dependencies change.

## WebRTC

Used for H.264 video and audio from PiKVM devices. Included as the prebuilt `WebRTC.xcframework` from [stasel/WebRTC](https://github.com/stasel/WebRTC) (build scripts under the BSD 3-Clause License), built from Google's WebRTC source. WebRTC also includes third-party components (such as BoringSSL, libvpx, libyuv and Opus) under their own permissive licenses, listed at <https://webrtc.org/support/license>.

```
Copyright (c) 2011, The WebRTC project authors. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of Google nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

WebRTC's additional patent grant is at <https://webrtc.googlesource.com/src/+/main/PATENTS>.

## Not included

The Openterface serial protocol is implemented from WCH's published CH9329 command set, not from Openterface's AGPL-licensed app, so no Openterface code is included.
