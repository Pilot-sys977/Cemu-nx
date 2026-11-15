#!/usr/bin/env bash
# Build devkitPro's stock switch-mesa 20.1.0-5 and switch-libdrm_nouveau 1.0.1-2
# from their official sources into an isolated staging prefix.
#
# Only the SDL launcher links this Mesa. The emulator core keeps using the
# unified Mesa 26.x SDK, which is never touched by this script. This exists
# because pkg.devkitpro.org refuses CI runners, so `dkp-pacman -Sw switch-mesa`
# (what build_switch_all.sh normally relies on) is not available there.
#
# The recipe mirrors devkitPro/pacman-packages switch/mesa/PKGBUILD and
# switch/libdrm_nouveau/PKGBUILD; every input is verified against the SHA-256
# published in those PKGBUILDs.
#
# Output: ${LAUNCHER_MESA20_STAGE}/opt/devkitpro/portlibs/switch
#         (default stage: dependencies/switch_deps/launcher_mesa20)
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/common.sh"
parse_check_only "$@"

PORTLIBS_PREFIX=/opt/devkitpro/portlibs/switch
STAGE="${LAUNCHER_MESA20_STAGE:-${SWITCH_DEPS_ROOT}/launcher_mesa20}"
OUT="${STAGE}${PORTLIBS_PREFIX}"
WORK="${SWITCH_DEPS_ROOT}/build/launcher_mesa20"
DOWNLOADS="${SWITCH_DEPS_ROOT}/downloads"

MESA_VER=20.1.0
MESA_DIR=mesa-${MESA_VER}-rc3
# Mesa moves old releases into older-versions/; try the official locations.
MESA_URLS=(
	"https://archive.mesa3d.org/older-versions/20.x/${MESA_DIR}.tar.xz"
	"https://mesa.freedesktop.org/archive/older-versions/20.x/${MESA_DIR}.tar.xz"
	"https://archive.mesa3d.org/${MESA_DIR}.tar.xz"
	"https://mesa.freedesktop.org/archive/${MESA_DIR}.tar.xz"
)
MESA_SHA=c90b75ea34302ebde9b81b87c5642fa864c40fe9c4ad34ce0793170c1413168d
PKGS_RAW="https://raw.githubusercontent.com/devkitPro/pacman-packages/master/switch/mesa"
declare -A MESA_PATCHES=(
	[switch-mesa-20.1.0-5.patch]=950f93d3e5b6ae9c5a42c2918623fe9a80d7ee398d92d2e73abec86b62d75916
	[gl_XML.py.patch]=a9bc326195b3fe29709e079466a8b2162a2ac9409f694eaad5494490155e2dd4
	[glX_XML.py.patch]=1475defcdf8600690eaddeee28d8f01310635c1273fb541f668e8789714d36ca
)
DRM_VER=1.0.1
DRM_URL="https://github.com/devkitPro/libdrm_nouveau/archive/v${DRM_VER}/libdrm_nouveau-src-${DRM_VER}.tar.gz"
DRM_SHA=b069bf8029abb120294bd2dd988dc4d6ce2be3f1016c88c26c73c87b6f312136

STAMP="${OUT}/share/cemu-launcher-mesa20.stamp"
STAMP_VALUE="mesa ${MESA_VER}-5 ${MESA_SHA} libdrm_nouveau ${DRM_VER}-2 ${DRM_SHA}"

is_ready() {
	[[ -f "${STAMP}" ]] && [[ "$(cat "${STAMP}")" == "${STAMP_VALUE}" ]] &&
		[[ -f "${OUT}/lib/libGLESv2.a" && -f "${OUT}/lib/libEGL.a" &&
		   -f "${OUT}/lib/libglapi.a" && -f "${OUT}/lib/libdrm_nouveau.a" ]] &&
		grep -q '^Version: 20\.1\.0' "${OUT}/lib/pkgconfig/glesv2.pc"
}

if (( CHECK_ONLY )); then
	is_ready || die "launcher Mesa 20.1.0 stage is missing; run dist/switch/deps/build_launcher_mesa20.sh"
	echo "Ready: launcher Mesa 20.1.0 (${OUT})"
	exit 0
fi
if is_ready; then
	echo "Already built: launcher Mesa 20.1.0 (${OUT})"
	exit 0
fi

for command_name in curl tar sha256sum patch make ninja python3 pkg-config; do
	require_command "${command_name}"
done
python3 -c 'import mako' 2>/dev/null || die "python3 Mako is required (pip install Mako)"
export PATH="${DEVKITPRO}/tools/bin:${DEVKITPRO}/devkitA64/bin:${PATH}"

# fetch <out> <sha256> <url>...: first URL whose content matches the hash wins.
fetch() {
	local out="$1" sha="$2" url
	shift 2
	if [[ -f "${out}" ]] && echo "${sha}  ${out}" | sha256sum --check --status -; then
		return
	fi
	for url in "$@"; do
		rm -f "${out}" "${out}.part"
		if curl -fL --retry 3 --retry-delay 5 -o "${out}.part" "${url}" &&
		   echo "${sha}  ${out}.part" | sha256sum --check --status -; then
			mv "${out}.part" "${out}"
			echo "Fetched ${url}"
			return
		fi
		echo "Unusable source (missing or checksum mismatch): ${url}" >&2
	done
	rm -f "${out}.part"
	die "could not obtain $(basename "${out}") with SHA-256 ${sha}"
}

rm -rf "${STAGE}" "${WORK}"
mkdir -p "${DOWNLOADS}" "${WORK}" "${OUT}"

# Meson: use the host's if present, otherwise a private virtualenv.
MESON="$(command -v meson || true)"
if [[ -z "${MESON}" ]]; then
	python3 -m venv "${WORK}/venv"
	"${WORK}/venv/bin/pip" install --quiet "meson==1.5.2"
	MESON="${WORK}/venv/bin/meson"
fi
echo ">> meson $("${MESON}" --version)"

echo ">> libdrm_nouveau ${DRM_VER}"
fetch "${DOWNLOADS}/libdrm_nouveau-${DRM_VER}.tar.gz" "${DRM_SHA}" "${DRM_URL}"
tar -xzf "${DOWNLOADS}/libdrm_nouveau-${DRM_VER}.tar.gz" -C "${WORK}"
make -C "${WORK}/libdrm_nouveau-${DRM_VER}"
make -C "${WORK}/libdrm_nouveau-${DRM_VER}" DESTDIR="${STAGE}" install
[[ -f "${OUT}/lib/libdrm_nouveau.a" ]] || die "libdrm_nouveau did not install into ${OUT}"

# pkg-config view: staged libdrm_nouveau first, then the regular portlibs.
mkdir -p "${WORK}/pkgconfig"
sed "s|^prefix=.*|prefix=${OUT}|" "${OUT}/lib/pkgconfig/libdrm_nouveau.pc" \
	> "${WORK}/pkgconfig/libdrm_nouveau.pc"
cat > "${WORK}/pkg-config" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_DIR= PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=
export PKG_CONFIG_LIBDIR="${WORK}/pkgconfig:${DEVKITPRO}/portlibs/switch/lib/pkgconfig"
[[ "\$1" == '--version' ]] && exec pkg-config --version
exec pkg-config --static "\$@"
EOF
chmod +x "${WORK}/pkg-config"

echo ">> Mesa ${MESA_VER}"
fetch "${DOWNLOADS}/${MESA_DIR}.tar.xz" "${MESA_SHA}" "${MESA_URLS[@]}"
for patch_name in "${!MESA_PATCHES[@]}"; do
	fetch "${DOWNLOADS}/${patch_name}" "${MESA_PATCHES[${patch_name}]}" "${PKGS_RAW}/${patch_name}"
done
tar -xJf "${DOWNLOADS}/${MESA_DIR}.tar.xz" -C "${WORK}"
(
	cd "${WORK}/${MESA_DIR}"
	patch -p1 -i "${DOWNLOADS}/switch-mesa-20.1.0-5.patch"
	patch -p1 -i "${DOWNLOADS}/gl_XML.py.patch"
	patch -p1 -i "${DOWNLOADS}/glX_XML.py.patch"

	# Equivalent of /opt/devkitpro/meson-cross.sh, but with the staged pkg-config.
	"${DEVKITPRO}/meson-toolchain.sh" switch > "${WORK}/crossfile.txt"
	sed -i -E "s|^pkgconfig = .*|pkgconfig = '${WORK}/pkg-config'|" "${WORK}/crossfile.txt"
	grep -q "^pkgconfig = '${WORK}/pkg-config'" "${WORK}/crossfile.txt" ||
		die "could not point the meson cross file at the staged pkg-config"
	"${MESON}" setup --buildtype=plain --cross-file="${WORK}/crossfile.txt" \
		--default-library=static --prefix="${PORTLIBS_PREFIX}" --libdir=lib \
		-Db_ndebug=true "${WORK}/mesa-build"
)
ninja -C "${WORK}/mesa-build"
DESTDIR="${STAGE}" ninja -C "${WORK}/mesa-build" install
sed -i "s,-lEGL,-lEGL -ldrm_nouveau," "${OUT}/lib/pkgconfig/egl.pc"

mkdir -p "$(dirname "${STAMP}")"
printf '%s\n' "${STAMP_VALUE}" > "${STAMP}"
is_ready || die "launcher Mesa stage is incomplete"
echo "Done: launcher Mesa 20.1.0 at ${OUT}"
