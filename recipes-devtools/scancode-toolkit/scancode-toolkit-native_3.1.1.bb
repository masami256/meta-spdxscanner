SUMMARY = "ScanCode toolkit"
DESCRIPTION = "A typical software project often reuses hundreds of third-party \
packages. License and origin information is not always easy to find and not \
normalized: ScanCode discovers and normalizes this data for you."
HOMEPAGE = "https://github.com/nexB/scancode-toolkit"
SECTION = "devel"

LICENSE = "Apache-2.0"
LIC_FILES_CHKSUM = "file://NOTICE;md5=1b6f6f8c3c1cdf360ee512a29241127b"

inherit native


DEPENDS = "xz-native zlib-native libxml2-native \
	   libxslt-native bzip2-native \
           "

SRC_URI = "git://github.com/nexB/scancode-toolkit;branch=develop \
          "

SRCREV = "ba4bbf216c6f44572662d16c76214a08b0a69e7e"

S = "${WORKDIR}/git"
B = "${S}"

export PYTHON_EXE="${HOSTTOOLS_DIR}/python"

do_configure(){
	./scancode --help
}

do_install_append(){
	install -d ${D}${bindir}/bin
	install -d ${D}${bindir}/include
	install -d ${D}${bindir}/local

	install ${S}/scancode ${D}${bindir}/
	cp -rf ${S}/bin/* ${D}${bindir}/bin/
}

