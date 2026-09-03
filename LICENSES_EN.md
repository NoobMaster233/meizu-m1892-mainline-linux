# Licensing

[简体中文](LICENSES.md) | **English**

Individual components retain their upstream licenses.  In particular:

- Linux kernel changes and loadable kernel modules: GPL-2.0-only unless their
  source header states another compatible license;
- postmarketOS device packaging: the license stated in each file/package;
- M1892 project-authored shell/OpenRC integration sources: MIT under the
  bundled `licenses/MIT.txt`; release scripts additionally carry an explicit
  `SPDX-License-Identifier: MIT` header;
- EDK2: upstream BSD-2-Clause-Patent and component-specific notices;
- Phoc 0.56.0 and the bundled M1892 patch: GPL-3.0-or-later; the
  standalone build helper is MIT;
- Alpine/postmarketOS packages, Phosh, Mesa, ES-DE, RetroArch and PPSSPP:
  their respective upstream licenses;
- `linux-msm/rmtfs` and the official Alpine `rmtfs` packages: BSD-3-Clause.
- `pyosmocom` 0.0.11, pinned and bundled in the call runtime:
  GPL-2.0-or-later;
- `python-statemachine` 2.5.0, pinned and bundled in the call runtime: MIT.
- callaudiod in the call runtime: GPL-3.0;
- 81voltd in the call runtime: GPL-2.0;
- qcom-imsd in the call runtime: GPL-2.0-or-later;
- the ModemManager daemon in the call runtime: GPL-2.0, with its library
  interface portions under LGPL-2.1;
- libqmi in the call runtime: GPL-2.0 for the tools and LGPL-2.1 for the
  shared library.

Those two pure-Python dependencies are downloaded from the official PyPI file
endpoint. The build helper verifies pinned SHA-256 values before extraction and
retains the wheels' license and metadata files in the runtime archive.
The upstream license texts for callaudiod, 81voltd, libqmi, qcom-imsd and
ModemManager are also copied into
`/usr/share/licenses/m1892-telephony-audio-runtime/` in the runtime archive and
the project MIT notice is installed alongside them. The archive verifier checks
each notice individually.

Source and license origins are pinned to the commits recorded by the build
helpers:

- [callaudiod](https://gitlab.com/mobian1/callaudiod),
  [81voltd](https://gitlab.postmarketos.org/modem/81voltd),
  [libqmi](https://gitlab.postmarketos.org/modem/openimsd/libqmi),
  [qcom-imsd](https://gitlab.postmarketos.org/modem/openimsd/qcom-imsd), and
  [ModemManager](https://gitlab.freedesktop.org/mobile-broadband/ModemManager);
- the [Linux kernel](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git),
  [Phoc](https://gitlab.gnome.org/World/Phosh/phoc),
  [EDK2](https://github.com/tianocore/edk2), and
  [rmtfs](https://github.com/linux-msm/rmtfs).

The source archive also carries the GPL-2.0, GPL-3.0, LGPL-2.1,
BSD-3-Clause, BSD-2-Clause-Patent, and MIT texts under `licenses/`. Each file's
own SPDX header or upstream declaration remains authoritative.
The Release also carries `m1892-telephony-audio-source.tar.gz`, containing the
pinned upstream snapshots, project patches, pure-Python dependency wheels,
build helpers and licenses corresponding to the call runtime.

The firmware extractor invokes (but does not bundle) `ath10k-bdencoder` from
qca-swiss-army-knife commit `34fa4d6bd6641c79e6a6384816314fbbcd5a23cc`,
whose source carries the Qualcomm Atheros permissive notice. Obtain that tool
from its upstream repository and retain its notice.

No license is granted here for Meizu/Qualcomm/vendor firmware, stock boot or
recovery bytes, game ROMs, scraped media or other third-party proprietary
content.  Those objects are excluded from the public repository and release
assets.

The current compressed base is an aggregate of the package set
recorded by the build metadata plus project integration files. It contains the
packages' installed license data and the ES-DE/PPSSPP license/resource trees,
but no vendor firmware, ROM, scraped media or device identity. Corresponding
package source remains available from the pinned Alpine/postmarketOS and
upstream repositories identified by the build records. It is a build input,
not a firmware-complete system image.

License and source pointers define the public boundary but are not a claim that
every binary can be rebuilt byte-for-byte. EDK2 cross-host byte identity is not
guaranteed, and some delivered binaries still lack a complete public
from-scratch rebuild path. Release metadata must retain exact binary hashes and
the corresponding source/license records.

Before a GitHub release, the generated source archive must include all license
and notice files required by the selected components and the verifier must
report no proprietary payload.
