#!/bin/sh
# shellcheck source=/dev/null
#
# Simple package manager written in POSIX shell for https://kisslinux.org
#
# The MIT License (MIT)
#
# Copyright (c) 2019-2021 Dylan Araps
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

SCRIPT_PATH=/home/whatever/nixDots/kiss

KISS_PATH=$SCRIPT_PATH/repo/core:$SCRIPT_PATH/my-repo/customized-packages

log() {
    printf '%b%s %b%s%b %s\n' \
        "$c1" "${3:-->}" "${c3}${2:+$c2}" "$1" "$c3" "$2" >&2
}

war() {
    log "$1" "$2" "${3:-WARNING}"
}

die() {
    log "$1" "$2" "${3:-ERROR}"
    exit 1
}

run() {
    # Print the command, then run it.
    printf '%s\n' "$*"
    "$@"
}

contains() {
    # Check if a "string list" contains a word.
    case " $1 " in *" $2 "*) return 0; esac; return 1
}

equ() {
    # Check if a string is equal to enother.
    # This replaces '[ "$var" = str ]' and '[ "$var" != str ]'.
    case $1 in "$2") return 0 ;; *) return 1; esac
}

ok() {
    # Check if a string is non-null.
    # This replaces '[ "$var" ]', '[ -n "$var" ]'.
    case $1 in '') return 1 ;; *) return 0; esac
}

null() {
    # Check if a string is non-null.
    # This replaces '[ -z "$var" ]'.
    case $1 in '') return 0 ;; *) return 1; esac
}

tmp_file() {
    # Create a uniquely named temporary file and store its absolute path
    # in a variable (_tmp_file).
    #
    # To prevent subshell usage and to handle cases where multiple files
    # are needed, this saves the last two temporary files to variables
    # for access by the caller (allowing 3 files at once).
    _tmp_file_pre_pre=$_tmp_file_pre
    _tmp_file_pre=$_tmp_file
    _tmp_file=$tmp_dir/$1-$2

    : > "$_tmp_file" || die "$1" "Failed to create temporary file"
}

tmp_file_copy() {
    # Create a uniquely named temporary file and make a duplicate of
    # the file in '$3' if it exists.
    tmp_file "$1" "$2"

    ! [ -f "$3" ] || cp -f "$3" "$_tmp_file"
}

prompt() {
    null "$1" || log "$1"

    log "Continue?: Press Enter to continue or Ctrl+C to abort"

    # korn-shell does not exit on interrupt of read.
    equ "$KISS_PROMPT" 0 || read -r _ || exit 1
}

mkcd() {
    mkdir -p "$@" && cd "$1"
}

fnr() {
    # Replace all occurrences of substrings with substrings. This
    # function takes pairs of arguments iterating two at a time
    # until everything has been replaced.
    _fnr=$1
    shift 1

    while :; do case $_fnr-$# in
        *"$1"*) _fnr=${_fnr%"$1"*}${2}${_fnr##*"$1"} ;;
           *-2) break ;;
             *) shift 2
    esac done
}

am_owner() {
    # Figure out if we need to change users to operate on
    # a given file or directory.
    inf=$(ls -ld "$1") ||
        die "Failed to file information for '$1'"

    # Split the ls output into fields.
    read -r _ _ user _ <<EOF
$inf
EOF

    equ "$LOGNAME/$user" "$user/$LOGNAME"
}

as_user() {
    printf 'Using '%s' (to become %s)\n' "$cmd_su" "$user"

    case ${cmd_su##*/} in
        su) "$cmd_su" -c "$* <&3" "$user" 3<&0 </dev/tty ;;
         *) "$cmd_su" -u "$user" -- "$@"
    esac
}

pkg_owner() {
    ok "$2" || { set +f; set -f -- "$1" "$sys_db"/*/manifest; }

    _owns=$(grep -lxF "$@")
    _owns=${_owns%/*}
    _owns=${_owns##*/}

    ok "$_owns"
}

resolve_path() {
    _rpath=$KISS_ROOT/${1#/}

    if cd -P "${_rpath%/*}" 2>/dev/null; then
        _parent=$PWD
        cd "$OLDPWD"
    else
        _parent=${_rpath%/*}
    fi

    _rpath=${_parent#"$KISS_ROOT"}/${_rpath##*/}
}

run_hook() {
    # Run all hooks in KISS_HOOK (a colon separated
    # list of absolute file paths).
    IFS=:

    for hook in ${KISS_HOOK:-}; do case $hook in *?*)
        "$hook" "$@" || die "$1 hook failed: '$hook'"
    esac done

    unset IFS
}

run_hook_pkg() {
    # Run a hook from the package's database files.
    if [ -x "$sys_db/$2/$1" ]; then
        log "$2" "Running $1 hook"
        "$sys_db/$2/$1"

    elif [ -f "$sys_db/$2/$1" ]; then
        war "$2" "skipping $1 hook: not executable"
    fi
}

decompress() {
    case $1 in
        *.tbz|*.bz2) bzip2 -d ;;
        *.lzma)      lzma -dc ;;
        *.lz)        lzip -dc ;;
        *.tar)       cat      ;;
        *.tgz|*.gz)  gzip -d  ;;
        *.xz|*.txz)  xz -dc ;;
        *.zst)       zstd -dc ;;
    esac < "$1"
}

sh256() {
    # Higher level sh256 function which filters out non-existent
    # files (and also directories).
    for f do shift
        [ -d "$f" ] || [ ! -e "$f" ] || set -- "$@" "$f"
    done

    _sh256 "$@"
}

_sh256() {
    # There's no standard utility to generate sha256 checksums.
    # This is a simple wrapper around sha256sum, sha256, shasum,
    # openssl, digest, ... which will use whatever is available.
    #
    # All utilities must match 'sha256sum' output.
    #
    # Example: '<checksum>  <file>'
    unset hash

    # Skip generation if no arguments.
    ! equ "$#" 0 || return 0

    # Set the arguments based on found sha256 utility.
    case ${cmd_sha##*/} in
        openssl) set -- dgst -sha256 -r "$@" ;;
         sha256) set -- -r "$@" ;;
         shasum) set -- -a 256 "$@" ;;
         digest) set -- -a sha256 "$@" ;;
    esac

    IFS=$newline

    # Generate checksums for all input files. This is a single
    # call to the utility rather than one per file.
    _hash=$("$cmd_sha" "$@") || die "Failed to generate checksums"

    # Strip the filename from each element.
    # '<checksum> ?<file>' -> '<checksum>'
    for sum in $_hash; do
        hash=$hash${hash:+"$newline"}${sum%% *}
    done

    printf '%s\n' "$hash"
    unset IFS
}

pkg_find_version() {
    ver_pre=$repo_ver
    rel_pre=$repo_rel

    pkg_find "$@"

    read -r repo_ver repo_rel 2>/dev/null < "$repo_dir/version" ||
        die "$1" "Failed to read version file ($repo_dir/version)"

    ok "$repo_rel" ||
        die "$1" "Release field not found in version file"

    # This belongs somewhere else, for now it can live here.
    [ -x "$repo_dir/build" ] ||
        die "$pkg" "Build file not found or not executable"
}

pkg_find_version_split() {
    pkg_find_version "$@"

    # Split the version on '.+-_' to obtain individual components.
    IFS=.+-_ read -r repo_major repo_minor repo_patch repo_ident <<EOF
$repo_ver
EOF
}

pkg_find() {
    _pkg_find "$@" || die "'$1' not found"
}

_pkg_find() {
    # Figure out which repository a package belongs to by searching for
    # directories matching the package name in $KISS_PATH/*.
    set -- "$1" "$2" "$3" "${4:-"$KISS_PATH"}"
    IFS=:

    # Iterate over KISS_PATH, grabbing all directories which match the query.
    # Intentional.
    # shellcheck disable=2086
    for _find_path in $4 "${3:-$sys_db}"; do set +f
        for _find_pkg in "$_find_path/"$1; do
            test "${3:--d}" "$_find_pkg" && set -f -- "$@" "$_find_pkg"
        done
    done

    unset IFS

    # Show all search results if called from 'kiss search', else store the
    # values in variables. If there are 4 arguments, no package has been found.
    case $2-$# in
        *-4) return 1 ;;
         -*) repo_dir=$5; repo_name=${5##*/} ;;
          *) shift 4; printf '%s\n' "$@"
    esac
}

pkg_list_version() {
    # List installed packages. As the format is files and directories, this
    # just involves a simple for loop and file read.

    # Optional arguments can be passed to check for specific packages. If no
    # arguments are passed, list all.
    ok "$1" || { set +f; set -f -- "$sys_db"/*; }

    # Loop over each package and print its name and version.
    for _list_pkg do
        pkg_find_version "${_list_pkg##*/}" "" "" "$sys_db"

        printf '%s\n' "$repo_name $repo_ver-$repo_rel"
    done
}

pkg_cache() {
    # Find the tarball of a package using a glob. Use the user's set compression
    # method if found or first match of the below glob.
    pkg_find_version "$1"

    set +f -- "$bin_dir/$1@$repo_ver-$repo_rel.tar."
    set -f -- "$1$KISS_COMPRESS" "$1"*

    tar_file=$1

    # If the first match does not exist, use the second. If neither exist,
    # this function returns 1 and the caller handles the error.
    [ -f "$1" ] || { tar_file=$2; [ -f "$2" ]; }
}

pkg_source_resolve() {
    # Given a line of input from the sources file, return an absolute
    # path to the source if it already exists, error if not.
    unset _res _des _fnr

    ok "${2##\#*}" || return 0

    # Surround each replacement with substitutions to handled escaped markers.
    # First substitution turns '\MARKER' into ' ' (can't appear in sources as
    # they're already split on whitespace), second replaces 'MARKER' with its
    # value and the third, turns ' ' into 'MARKER' (dropping \\).
    fnr "${2%"${2##*[!/]}"}" \
        \\VERSION \  VERSION "$repo_ver"   \  VERSION \
        \\RELEASE \  RELEASE "$repo_rel"   \  RELEASE \
        \\MAJOR   \  MAJOR   "$repo_major" \  MAJOR \
        \\MINOR   \  MINOR   "$repo_minor" \  MINOR \
        \\PATCH   \  PATCH   "$repo_patch" \  PATCH \
        \\IDENT   \  IDENT   "$repo_ident" \  IDENT \
        \\PACKAGE \  PACKAGE "$repo_name"  \  PACKAGE

    set -- "$1" "$_fnr" "${3%"${3##*[!/]}"}" "$4"

    # Git repository.
    if null "${2##git+*}"; then
        _res=$2
        _des=$src_dir/$1/${3:+"$3/"}${2##*/}
        _des=${_des%[@#]*}/

    # Remote source (cached).
    elif [ -f "$src_dir/$1/${3:+"$3/"}${2##*/}" ]; then
        _res=$src_dir/$1/${3:+"$3/"}${2##*/}

    # Remote source.
    elif null "${2##*://*}"; then
        _res=url+$2
        _des=$src_dir/$1/${3:+"$3/"}${2##*/}

    # Local relative dir.
    elif [ -d "$repo_dir/$2" ]; then
        _res=$repo_dir/$2/.

    # Local absolute dir.
    elif [ -d "/${2##/}" ]; then
        _res=/${2##/}/.

    # Local relative file.
    elif [ -f "$repo_dir/$2" ]; then
        _res=$repo_dir/$2

    # Local absolute file.
    elif [ -f "/${2##/}" ]; then
        _res=/${2##/}

    else
        die "$1" "No local file '$2'"
    fi

    ok "$4" || printf 'found %s\n' "$_res"
}

pkg_source() {
    # Download any remote package sources. The existence of local files is
    # also checked.
    pkg_find_version_split "$1"

    # Support packages without sources. Simply do nothing.
    [ -f "$repo_dir/sources" ] || return 0

    log "$1" "Reading sources"

    while read -r src dest || ok "$src"; do
        pkg_source_resolve "$1" "$src" "$dest" "$2"

        # arg1: pre-source
        # arg2: package name
        # arg3: verbatim source
        # arg4: resolved source
        run_hook pre-source "$1" "$src" "$_fnr"

        # '$2' is set when this function is called from 'kiss c' and it is used
        # here to skip calling the Git code.
        case $2$_res in "$2url+"*|git+*)
            mkcd "${_des%/*}"
            "pkg_source_${_res%%+*}" "$_des" "${_res##"${_res%%+*}+"}"
        esac

        # arg1: post-source
        # arg2: package name
        # arg3: verbatim source
        # arg4: resolved source
        run_hook post-source "$1" "$src" "${_des:-"$_res"}"
    done < "$repo_dir/sources"
}

pkg_source_url() {
    log "$repo_name" "Downloading $2"

    # Set the arguments based on found download utility.
    case ${cmd_get##*/} in
        aria2c|axel) set -- -o   "$@" ;;
               curl) set -- -fLo "$@" ;;
         wget|wget2) set -- -O   "$@" ;;
    esac

    "$cmd_get" "$@" || {
        rm -f "$2"
        die "$repo_name" "Failed to download $3"
    }
}

pkg_source_git() {
    com=${2##*[@#]}
    com=${com#${2%[#@]*}}

    log "$repo_name" "Checking out ${com:-FETCH_HEAD}"

    [ -d .git ] || git init

    git remote set-url origin "${2%[#@]*}" 2>/dev/null ||
        git remote add origin "${2%[#@]*}"

    git fetch --depth=1 origin "$com"
    git reset --hard FETCH_HEAD
}

pkg_source_tar() {
    # This is a portable shell implementation of GNU tar's
    # '--strip-components 1'. Use of this function denotes a
    # performance penalty.
    tmp_file "$repo_name" tarball
    tmp_file "$repo_name" tarball-manifest

    decompress "$1" > "$_tmp_file_pre" ||
        die "$repo_name" "Failed to decompress $1"

    tar xf "$_tmp_file_pre" ||
        die "$repo_name" "Failed to extract $1"

    # The sort command filters out all duplicate top-level
    # directories from the tarball's manifest. This is an optimization
    # as we avoid looping (4000 times for Python(!)).
    tar tf "$_tmp_file_pre" | sort -ut / -k1,1 > "$_tmp_file" ||
        die "$repo_name" "Failed to extract manifest"

    # Iterate over all directories in the first level of the
    # tarball's manifest. Each directory is moved up a level.
    while IFS=/ read -r dir _; do case ${dir#.} in *?*)
        # Skip entries which aren't directories.
        [ -d "$dir" ] || continue

        # Move the parent directory to prevent naming conflicts
        # with the to-be-moved children.
        mv -f "$dir" "$KISS_PID-$dir"

        # Move all children up a directory level. If the mv command
        # fails, fallback to copying the remainder of the files.
        #
        # We can't use '-exec {} +' with any arguments between
        # the '{}' and '+' as this is not POSIX. We must also
        # use '$0' and '$@' to reference all arguments.
        find "$KISS_PID-$dir/." ! -name . -prune \
            -exec sh -c 'mv -f "$0" "$@" .' {} + 2>/dev/null ||

        find "$KISS_PID-$dir/." ! -name . -prune \
            -exec sh -c 'cp -fRp "$0" "$@" .' {} +

        # Remove the directory now that all files have been
        # transferred out of it. This can't be a simple 'rmdir'
        # as we may leave files in here if any were copied.
        rm -rf "$KISS_PID-$dir"
    esac done < "$_tmp_file"

    # Remove the tarball now that we are done with it.
    rm -f "$_tmp_file_pre"
}

pkg_extract() {
    # Extract all source archives to the build directory and copy over any
    # local repository files.
    #
    # NOTE: repo_dir comes from caller.
    log "$1" "Extracting sources"

    # arg1: pre-extract
    # arg2: package name
    # arg3: path to DESTDIR
    run_hook pre-extract "$pkg" "$pkg_dir/$pkg"

    while read -r src dest || ok "$src"; do
        pkg_source_resolve "$1" "$src" "$dest" >/dev/null

        # Create the source's directories if not null.
        null "$_res" || mkcd "$mak_dir/$1/$dest"

        case $_res in
            git+*)
                cp -LRf "$_des/." .
            ;;

            *.tar|*.tar.??|*.tar.???|*.tar.????|*.t?z)
                pkg_source_tar "$_res"
            ;;

            *?*)
                cp -LRf "$_res" .
            ;;
        esac
    done < "$repo_dir/sources" || die "$1" "Failed to extract $_res"
}

pkg_depends() {
    # Resolve all dependencies and generate an ordered list. The deepest
    # dependencies are listed first and then the parents in reverse order.
    ! contains "$deps" "$1" || return 0

    # Filter out non-explicit, already installed packages.
    null "$3" || ok "$2" || contains "$explicit" "$1" ||
        ! [ -d "$sys_db/$1" ] || return 0

    # Detect circular dependencies and bail out.
    # Looks for multiple repeating patterns of (dep dep_parent) (5 is max).
    case " $4 " in
*" ${4##* } "*" $1 "\
*" ${4##* } "*" $1 "\
*" ${4##* } "*" $1 "\
*" ${4##* } "*" $1 "\
*" ${4##* } "*" $1 "*)
        die "Circular dependency detected $1 <> ${4##* }"
    esac

    # Packages which exist and have depends.
    ! _pkg_find "$1" || ! [ -e "$repo_dir/depends" ] ||

    # Recurse through the dependencies of the child packages.
    while read -r dep dep_type || ok "$dep"; do
        ! ok "${dep##\#*}" || pkg_depends "$dep" '' "$3" "$4 $1" "$dep_type"
    done < "$repo_dir/depends" || :

    # Add parent to dependencies list.
    if ! equ "$2" expl || { equ "$5" make && ! pkg_cache "$1"; }; then
        deps="$deps $1"
    fi
}

pkg_order() {
    # Order a list of packages based on dependence and take into account
    # pre-built tarballs if this is to be called from 'kiss i'.
    unset order redro deps

    for pkg do case $pkg in
      /*@*.tar.*) deps="$deps $pkg" ;;
       *@*.tar.*) deps="$deps $ppwd/$pkg" ;;
             */*) die "Not a package' ($pkg)" ;;
               *) pkg_depends "$pkg" raw
    esac done

    # Filter the list, only keeping explicit packages. The purpose of these
    # two loops is to order the argument list based on dependence.
    for pkg in $deps; do case " $* " in *" $pkg "*|*" ${pkg##"$ppwd/"} "*)
        order="$order $pkg"
        redro="$pkg $redro"
    esac done

    unset deps
}

pkg_strip() {
    # Strip package binaries and libraries. This saves space on the system as
    # well as on the tarballs we ship for installation.
    [ -f "$mak_dir/$pkg/nostrip" ] || equ "$KISS_STRIP" 0 && return

    log "$1" "Stripping binaries and libraries"

    # Strip only files matching the below ELF types. This uses 'od' to print
    # the first 18 bytes of the file. This is the location of the ELF header
    # (up to the ELF type) and contains the type information we need.
    #
    # Static libraries (.a) are in reality AR archives which contain ELF
    # objects. We simply read from the same 18 bytes and assume that the AR
    # header equates to an archive containing objects (.o).
    #
    # Example ELF output ('003' is ELF type):
    # 0000000 177   E   L   F 002 001 001  \0  \0  \0  \0  \0  \0  \0  \0  \0
    # 0000020 003  \0
    # 0000022
    #
    # Example AR output (.a):
    # 0000000   !   <   a   r   c   h   >  \n   /
    # 0000020
    # 0000022
    while read -r file; do [ -h "$pkg_dir/$1$file" ] || case $file in
        # Look only in these locations for files of interest (libraries,
        # programs, etc). This includes all subdirectories. Old behavior
        # would run od on all files (upwards of 4000 for Python).
        */sbin/?*[!/]|*/bin/?*[!/]|*/lib/?*[!/]|\
        */lib??/?*[!/]|*/lib???/?*[!/]|*/lib????/?*[!/])

        case $(od -A o -t c -N 18 "$pkg_dir/$1$file") in
            # REL (object files (.o), static libraries (.a)).
            *177*E*L*F*0000020\ 001\ *|*\!*\<*a*r*c*h*\>*)
                run strip -g -R .comment -R .note "$pkg_dir/$1$file"
            ;;

            # EXEC (binaries), DYN (shared libraries).
            # Shared libraries keep global symbols in a separate ELF section
            # called '.dynsym'. '--strip-all/-s' does not touch the dynamic
            # symbol entries which makes this safe to do.
            *177*E*L*F*0000020\ 00[23]\ *)
                run strip -s -R .comment -R .note "$pkg_dir/$1$file"
            ;;
        esac
    esac done < "$pkg_dir/$1/$pkg_db/$1/manifest" || :
}

pkg_fix_deps() {
    # Dynamically look for missing runtime dependencies by checking each
    # binary and library with 'ldd'. This catches any extra libraries and or
    # dependencies pulled in by the package's build suite.
    log "$1" "looking for dependencies (using ${cmd_elf##*/})"

    tmp_file_copy "$1" depends depends
    tmp_file      "$1" depends-fixed

    set +f
    set -f -- "$sys_db/"*/manifest

    unset _fdep_seen

    # False positive (not a write).
    # shellcheck disable=2094
    while read -r _file; do [ -h "$_file" ] || case $_file in
        # Look only in these locations for files of interest (libraries,
        # programs, etc). This includes all subdirectories. Old behavior
        # would run ldd on all files (upwards of 4000 for Python).
        */sbin/?*[!/]|*/bin/?*[!/]|*/lib/?*[!/]|\
        */lib??/?*[!/]|*/lib???/?*[!/]|*/lib????/?*[!/])

        # The readelf mode requires ldd's output to resolve the library
        # path for a given file. If ldd fails, silently skip the file.
        ldd=$(ldd -- "$pkg_dir/$repo_name$_file" 2>/dev/null) || continue

        # Attempt to get information from readelf. If this fails (or we
        # are in ldd mode), do full ldd mode (which has the downside of
        # listing dependencies of dependencies (and so on)).
        elf=$("$cmd_elf" -d "$pkg_dir/$repo_name$_file" 2>/dev/null) || elf=$ldd

        # Iterate over the output of readelf or ldd, extract file names,
        # resolve their paths and finally, figure out their owner.
        while read -r lib; do case $lib in *NEEDED*\[*\]|*'=>'*)
            # readelf: 0x0000 (NEEDED) Shared library: [libjson-c.so.5]
            lib=${lib##*\[}
            lib=${lib%%\]*}

            # Resolve library path.
            # ldd: libjson-c.so.5 => /lib/libjson-c.so.5 ...
            case $cmd_elf in
                *readelf) lib=${ldd#*"	$lib => "} ;;
                *)        lib=${lib##*=> } ;;
            esac
            lib=${lib%% *}

            # Skip files owned by libc, libc++ and POSIX.
            case ${lib##*/} in
                ld-*           |\
                lib[cm].so*    |\
                libc++.so*     |\
                libc++abi.so*  |\
                libcrypt.so*   |\
                libdl.so*      |\
                libgcc_s.so*   |\
                libmvec.so*    |\
                libpthread.so* |\
                libresolv.so*  |\
                librt.so*      |\
                libstdc++.so*  |\
                libtrace.so*   |\
                libunwind.so*  |\
                libutil.so*    |\
                libxnet.so*    |\
                ldd)
                    continue
            esac

            # Skip files we have seen before.
            case " $_fdep_seen " in
                *" $lib "*) continue ;;
                *) _fdep_seen="$_fdep_seen $lib"
            esac

            resolve_path "$lib"

            # Skip file if owned by current package
            ! pkg_owner -e "$_rpath" manifest ||
                continue

            ! pkg_owner -e "$_rpath" "$@" ||
                printf '%s\n' "$_owns"

        esac done <<EOF || :
$elf
EOF
    esac done < manifest |

    # Sort the depends file (including the existing depends file) and
    # remove any duplicate entries. This can't take into account comments
    # so they remain rather than being replaced.
    sort -uk1,1 "$_tmp_file_pre" - > "$_tmp_file"

    # If the depends file was modified, show a diff and replace it.
    ! [ -s "$_tmp_file" ] || {
        diff -U 3 "$_tmp_file_pre" "$_tmp_file" 2>/dev/null || :

        # Replace the existing depends file if one exists, otherwise this
        # just moves the file to its final resting place.
        mv -f "$_tmp_file" depends

        # Generate a new manifest as we may be the creator of the depends
        # file. This could otherwise be implemented by inserting a line
        # at the correct place in the existing manifest.
        pkg_manifest "${PWD##*/}" "$pkg_dir"
    }
}

pkg_manifest() {
    # Generate the package's manifest file. This is a list of each file
    # and directory inside the package. The file is used when uninstalling
    # packages, checking for package conflicts and for general debugging.
    log "$1" "Generating manifest"

    tmp_file "$1" manifest

    # Create a list of all files and directories. Append '/' to the end of
    # directories so they can be easily filtered out later. Also filter out
    # all libtool .la files and charset.alias.
    {
        printf '%s\n' "$2/$1/$pkg_db/$1/manifest"

        ! [ -d "$2/$1/etc" ] ||
            printf '%s\n' "$2/$1/$pkg_db/$1/etcsums"

        find "$2/$1" ! -path "$2/$1" -type d -exec printf '%s/\n' {} + \
            -o \( ! -type d -a ! -name \*.la -a ! -name charset.alias \) -print

    # Sort the output in reverse. Directories appear after their contents.
    } | sort -ur > "$_tmp_file"

    # Remove the prefix from each line.
    while read -r file; do
        printf '%s\n' "${file#"$2/$1"}"
    done < "$_tmp_file" > "$2/$1/$pkg_db/$1/manifest"
}

pkg_manifest_validate() {
    # NOTE: _pkg comes from caller.
    log "$_pkg" "Checking if manifest valid"

    while read -r line; do
        [ -e "$tar_dir/$_pkg$line" ] || [ -h "$tar_dir/$_pkg$line" ] || {
            printf '%s\n' "$line"
            set -- "$@" "$line"
        }
    done < "$pkg_db/$_pkg/manifest"

    for f do
        die "$_pkg" "manifest contains $# non-existent files"
    done
}

pkg_manifest_replace() {
    # Replace the matching line in the manifest with the desired replacement.
    # This used to be a 'sed' call which turned out to be a little
    # error-prone in some cases. This new method is a tad slower but ensures
    # we never wipe the file due to a command error.
    tmp_file "$1" "manifest-replace-${2##*/}"

    while read -r line; do
        ! equ "$line" "$2" || line=$3

        printf '%s\n' "$line"
    done < "$sys_db/$1/manifest" | sort -r > "$_tmp_file"

    mv -f "$_tmp_file" "$sys_db/$1/manifest"
}

pkg_etcsums() {
    # Generate checksums for each configuration file in the package's /etc/
    # directory for use in "smart" handling of these files.
    log "$repo_name" "Generating etcsums"

    # Minor optimization - skip packages without /etc/.
    [ -d "$pkg_dir/$repo_name/etc" ] || return 0

    # Create a list of all files in etc but do it in reverse.
    while read -r etc; do case $etc in /etc/*[!/])
        set -- "$pkg_dir/$repo_name/$etc" "$@"
    esac done < manifest

    sh256 "$@" > etcsums
}

pkg_tar() {
    # Create a tarball from the built package's files. This tarball also
    # contains the package's database entry.
    #
    # NOTE: repo_ comes from caller.
    log "$1" "Creating tarball"

    _tar_file=$bin_dir/$1@$repo_ver-$repo_rel.tar.$KISS_COMPRESS

    # Use 'cd' to avoid needing tar's '-C' flag which may not be portable
    # across implementations.
    cd "$pkg_dir/$1"

    # Create a tarball from the contents of the built package.
    tar cf - . | case $KISS_COMPRESS in
        bz2)  bzip2 -z ;;
        gz)   gzip -6  ;;
        lzma) lzma -z  ;;
        lz)   lzip -z  ;;
        xz)   xz -z  ;;
        zst)  zstd -z  ;;
    esac > "$_tar_file"

    cd "$OLDPWD"

    log "$1" "Successfully created tarball"

    # arg1: post-package
    # arg2: package name
    # arg3: path to tarball
    run_hook post-package "$1" "$_tar_file"
}

pkg_build_all() {
    # Build packages and turn them into packaged tarballs.
    # Order the argument list and filter out duplicates.

    # Mark packages passed on the command-line explicit.
    # Also resolve dependencies for all explicit packages.
    for pkg do
        pkg_depends "$pkg" expl filter
        explicit="$explicit $pkg "
    done

    # If this is an update, don't always build explicitly passsed packages
    # and instead install pre-built binaries if they exist.
    ok "$prefer_cache" || explicit_build=$explicit

    set --

    # If an explicit package is a dependency of another explicit package,
    # remove it from the explicit list.
    for pkg in $explicit; do
        contains "$deps" "$pkg" || set -- "$@" "$pkg"
    done
    explicit_cnt=$#
    explicit=$*

    log "Building: explicit: $*${deps:+, implicit: ${deps## }}"

    # Intentional, globbing disabled.
    # shellcheck disable=2046,2086
    set -- $deps "$@"

    # Ask for confirmation if extra packages need to be built.
    equ "$#" "$explicit_cnt" || prompt

    log "Checking for pre-built dependencies"

    # Install any pre-built dependencies if they exist in the binary
    # directory and are up to date.
    for pkg in "$@"; do
        if ! contains "$explicit_build" "$pkg" && pkg_cache "$pkg"; then
            log "$pkg" "Found pre-built binary"

            # Intended behavior.
            # shellcheck disable=2030,2031
            (export KISS_FORCE=1; args i "$tar_file")
        else
            set -- "$@" "$pkg"
        fi

        shift
    done

    for pkg do
        pkg_source "$pkg"

        ! [ -f "$repo_dir/sources" ] || pkg_verify "$pkg"
    done

    # Finally build and create tarballs for all passed packages and
    # dependencies.
    for pkg do
        log "$pkg" "Building package ($((_build_cur+=1))/$#)"

        pkg_find_version_split "$pkg"

        # arg1: queue-status
        # arg2: package name
        # arg3: number in queue
        # arg4: total in queue
        run_hook queue "$pkg" "$_build_cur" "$#"

        ! [ -f "$repo_dir/sources" ] || pkg_extract  "$pkg"

        pkg_build    "$pkg"
        pkg_manifest "$pkg" "$pkg_dir"
        pkg_strip    "$pkg"

        cd "$pkg_dir/$pkg/$pkg_db/$pkg"

        pkg_fix_deps "$pkg"
        pkg_etcsums
        pkg_tar      "$pkg"

        if equ "${prefer_cache:=0}" 1 || ! contains "$explicit" "$pkg"; then
            log "$pkg" "Needed as a dependency or has an update, installing"

            # Intended behavior.
            # shellcheck disable=2030,2031
            (export KISS_FORCE=1; args i "$pkg")
        fi
    done

    # Intentional, globbing disabled.
    # shellcheck disable=2046,2086
    ! equ "${build_install:=1}" 1 || ! equ "${KISS_PROMPT:=1}" 1 ||
        ! prompt "Install built packages? [$explicit]" || (args i $explicit)
}

pkg_build() {
    # Install built packages to a directory under the package name to
    # avoid collisions with other packages.
    mkcd "$mak_dir/$1" "$pkg_dir/$1/$pkg_db"

    log "$1" "Starting build"

    # arg1: pre-build
    # arg2: package name
    # arg3: path to build directory
    run_hook pre-build "$1" "$mak_dir/$1"

    # Attempt to create the log file early so any permissions errors are caught
    # before the build starts. 'tee' is run in a pipe and POSIX shell has no
    # pipe-fail causing confusing behavior when tee fails.
    : > "$log_dir/$1-$time-$KISS_PID"

    # Call the build script, log the output to the terminal and to a file.
    # There's no PIPEFAIL in POSIX shell so we must resort to tricks like kill.
    {
        # Give the script a modified environment. Define toolchain program
        # environment variables assuming a generic environment by default.
        #
        # Define DESTDIR and GOPATH to sane defaults as their use is mandatory
        # in anything using autotools, meson, cmake, etc. Define KISS_ROOT as
        # the sanitized value used internally by the package manager. This is
        # safe to join with other paths.
        AR="${AR:-ar}" \
        CC="${CC:-cc}" \
        CXX="${CXX:-c++}" \
        NM="${NM:-nm}" \
        RANLIB="${RANLIB:-ranlib}" \
        DESTDIR="$pkg_dir/$1" \
        RUSTFLAGS="--remap-path-prefix=$PWD=. $RUSTFLAGS" \
        GOFLAGS="-trimpath -modcacherw $GOFLAGS" \
        GOPATH="$PWD/go" \
        KISS_ROOT="$KISS_ROOT" \
        \
        "$repo_dir/build" "$pkg_dir/$1" "$repo_ver" 2>&1 || {
            log "$1" "Build failed"
            log "$1" "Log stored to $log_dir/$1-$time-$KISS_PID"

            # arg1: build-fail
            # arg2: package name
            # arg3: path to build directory
            (run_hook build-fail "$pkg" "$mak_dir/$1") || :

            pkg_clean
            kill 0
        }
    } | tee "$log_dir/$1-$time-$KISS_PID"

    # Delete the log file if the build succeeded to prevent the directory
    # from filling very quickly with useless logs.
    equ "$KISS_KEEPLOG" 1 || rm -f "$log_dir/$1-$time-$KISS_PID"

    # Copy the repository files to the package directory.
    cp -LRf "$repo_dir" "$pkg_dir/$1/$pkg_db/"

    log "$1" "Successfully built package"

    # arg1: post-build
    # arg2: package name
    # arg3: path to DESTDIR
    run_hook post-build "$1" "$pkg_dir/$1"
}

pkg_checksum() {
    pkg_source "$1" c

    [ -f "$repo_dir/sources" ] || return 0

    pkg_checksum_gen

    if ok "$hash"; then
        printf '%s\n' "$hash" > "$repo_dir/checksums"
        log "$1" "Generated checksums"

    else
        log "$1" "No sources needing checksums"
    fi
}

pkg_checksum_gen() {
    # Generate checksums for packages.
    #
    # NOTE: repo_ comes from caller.
    while read -r src dest || ok "$src"; do
        pkg_source_resolve "$repo_name" "$src" "$dest" >/dev/null

        case ${_res##git+*} in */*[!.])
            set -- "$@" "$_res"
        esac
    done < "$repo_dir/sources"

    _sh256 "$@"
}

pkg_verify() {
    # Verify all package checksums. This is achieved by generating a new set
    # of checksums and then comparing those with the old set.
    #
    # NOTE: repo_dir comes from caller.
    log "$repo_name" "Verifying sources"

    # Generate a new set of checksums to compare against.
    pkg_checksum_gen >/dev/null

    # Intentional, globbing disabled.
    # shellcheck disable=2038,2086
    set -- $hash

    # Check that the first column (separated by whitespace) match in both
    # checksum files. If any part of either file differs, mismatch. Abort.
    null "$1" || while read -r chk _ || ok "$1"; do
        printf '%s\n%s\n' "- ${chk:-missing}" "+ ${1:-no source}"

        equ "$1-${chk:-null}" "$chk-$1" ||
        equ "$1-${chk:-null}" "$1-SKIP" ||
            die "$repo_name" "Checksum mismatch"

        shift "$(($# != 0))"
    done < "$repo_dir/checksums"
}

pkg_conflicts() {
    # Check to see if a package conflicts with another.
    # _pkg comes from the caller.
    log "$_pkg" "Checking for package conflicts"

    tmp_file "$_pkg" manifest-files
    tmp_file "$_pkg" found-conflicts

    # Filter the tarball's manifest and select only files. Resolve all
    # symlinks in file paths as well.
    while read -r file; do case $file in *[!/])
        resolve_path "$file"

        printf '%s\n' "$_rpath"
    esac done < "$PWD/$pkg_db/$_pkg/manifest" > "$_tmp_file_pre"

    cd "$tar_dir/$_pkg"
    set +f
    set -f "$sys_db"/*/manifest

    # Remove the current package from the manifest list.
    fnr " $* " " $sys_db/$_pkg/manifest " " "

    # Intentional, globbing disabled.
    # shellcheck disable=2046,2086
    set -- $_fnr

    # Return here if there is nothing to check conflicts against.
    ! equ "$#" 0 || return 0

    # Store the list of found conflicts in a file as we'll be using the
    # information multiple times. Storing things in the cache dir allows
    # us to be lazy as they'll be automatically removed on script end.
    grep -Fxf "$_tmp_file_pre" -- "$@" 2>/dev/null > "$_tmp_file" || :

    # Enable alternatives automatically if it is safe to do so.
    # This checks to see that the package that is about to be installed
    # doesn't overwrite anything it shouldn't in '/var/db/kiss/installed'.
    grep -q ":/var/db/kiss/installed/" "$_tmp_file" || safe=1

    if ! equ "$KISS_CHOICE" 1 && equ "$safe" 1 && [ -s "$_tmp_file" ]; then
        # This is a novel way of offering an "alternatives" system.
        # It is entirely dynamic and all "choices" are created and
        # destroyed on the fly.
        #
        # When a conflict is found between two packages, the file
        # is moved to a directory called "choices" and its name
        # changed to store its parent package and its intended
        # location.
        #
        # The package's manifest is then updated to reflect this
        # new location.
        #
        # The 'kiss alternatives' command parses this directory and
        # offers you the CHOICE of *swapping* entries in this
        # directory for those on the filesystem.
        #
        # The alternatives command does the same thing we do here,
        # it rewrites manifests and moves files around to make
        # this work.
        #
        # Pretty nifty huh?
        while IFS=: read -r _ con; do
            printf '%s\n' "Found conflict $con"

            # Create the "choices" directory inside of the tarball.
            # This directory will store the conflicting file.
            mkdir -p "$PWD/$cho_db"

            # Construct the file name of the "db" entry of the
            # conflicting file. (pkg_name>usr>bin>ls)
            fnr "$con" '/' '>'

            # Move the conflicting file to the choices directory
            # and name it according to the format above.
            mv -f "$PWD$con" "$PWD/$cho_db/$_pkg$_fnr" 2>/dev/null || {
                log "File must be in ${con%/*} and not a symlink to it"
                log "This usually occurs when a binary is installed to"
                die "/sbin instead of /usr/bin (example)"
            }
        done < "$_tmp_file"

        log "$_pkg" "Converted all conflicts to choices (kiss a)"

        # Rewrite the package's manifest to update its location
        # to its new spot (and name) in the choices directory.
        pkg_manifest "$_pkg" "$tar_dir"

    elif [ -s "$_tmp_file" ]; then
        log "Package '$_pkg' conflicts with another package" "" "!>"
        log "Run 'KISS_CHOICE=1 kiss i $_pkg' to add conflicts" "" "!>"
        die "as alternatives." "" "!>"
    fi
}

pkg_alternatives() {
    if equ "$1" -; then
        while read -r pkg path; do
            pkg_swap "$pkg" "$path"
        done

    elif ok "$1"; then
        pkg_swap "$@"

    else
        # Go over each alternative and format the file
        # name for listing. (pkg_name>usr>bin>ls)
        set +f; for pkg in "$sys_ch/"*; do
            fnr "${pkg##*/}" '>' '/'
            printf '%s %s\n' "${_fnr%%/*}" "/${_fnr#*/}"
        done
    fi
}

pkg_swap() {
    # Swap between package alternatives.
    [ -d "$sys_db/$1" ] || die "'$1' not found"

    fnr "$1$2" '/' '>'

    [ -f "$sys_ch/$_fnr" ] || [ -h "$sys_ch/$_fnr" ] ||
        die "Alternative '$1 ${2:-null}' doesn't exist"

    if [ -f "$KISS_ROOT$2" ]; then
        pkg_owner "/${2#/}" ||
            die "File '$2' exists on filesystem but isn't owned"

        log "Swapping '$2' from '$_owns' to '$1'"

        # Convert the current owner to an alternative and rewrite its manifest
        # file to reflect this.
        cp -Pf "$KISS_ROOT$2" "$sys_ch/$_owns>${_fnr#*>}"
        pkg_manifest_replace "$_owns" "$2" "/$cho_db/$_owns>${_fnr#*>}"
    fi

    # Convert the desired alternative to a real file and rewrite the manifest
    # file to reflect this. The reverse of above.
    mv -f "$sys_ch/$_fnr" "$KISS_ROOT/$2"
    pkg_manifest_replace "$1" "/$cho_db/$_fnr" "$2"
}

file_rwx() {
    # Convert the output of 'ls' (rwxrwx---) to octal. This is simply
    # a 1-9 loop with the second digit being the value of the field.
    #
    # NOTE: This drops setgid/setuid permissions and does not include
    # them in the conversion. This is intentional.
    unset oct o

    rwx=$(ls -ld "$1")

    for c in 14 22 31 44 52 61 74 82 91; do
        rwx=${rwx#?}

        case $rwx in
            [rwx]*) o=$((o + ${c#?})) ;;
             [st]*) o=$((o + 1)) ;;
        esac

        case $((${c%?} % 3)) in 0)
            oct=$oct$o
            o=0
        esac
    done
}

pkg_install_files() {
    # Copy files and create directories (preserving permissions).
    # The 'test $1' will run with '-z' for overwrite and '-e' for verify.
    while { read -r file && _file=$KISS_ROOT$file; } do case $file in
        */)
            # Skip directories if they already exist in the file system.
            # (Think /usr/bin, /usr/lib, etc).
            [ -d "$_file" ] || {
                file_rwx "$2/${file#/}"
                mkdir -m "$oct" "$_file"
            }
        ;;

        *)
            # Skip directories and files which exist in verify mode.
            [ -d "$_file" ] || ! test "$1" "$_file" ||
                continue

            case $file in /etc/*[!/])
                # Handle /etc/ files in a special way (via a 3-way checksum) to
                # determine how these files should be installed. Do we overwrite
                # the existing file? Do we install it as $file.new to avoid
                # deleting user configuration? etc.
                #
                # This is more or less similar to Arch Linux's Pacman with the
                # user manually handling the .new files when and if they appear.
                pkg_etc || continue
            esac

            if [ -h "$_file" ]; then
                # Copy the file to the destination directory overwriting
                # any existing file.
                cp -fP "$2$file" "${_file%/*}/."

            else
                # Construct a temporary filename which is a) unique and
                # b) identifiable as related to the package manager.
                __tmp=${_file%/*}/__kiss-tmp-$_pkg-${file##*/}-$KISS_PID

                # Copy the file to the destination directory with the
                # temporary name created above.
                cp -fP "$2$file" "$__tmp" &&

                # Atomically move the temporary file to its final
                # destination. The running processes will either get
                # the old file or the new one.
                mv -f "$__tmp" "$_file"
            fi
    esac || return 1; done
}

pkg_remove_files() {
    # Remove a file list from the system. This function runs during package
    # installation and package removal. Combining the removals in these two
    # functions allows us to stop duplicating code.
    while read -r file; do
        case $file in /etc/?*[!/])
            sh256 "$KISS_ROOT/$file" >/dev/null

            read -r sum_pkg <&3 ||:

            equ "$hash" "$sum_pkg" || {
                printf 'Skipping %s (modified)\n' "$file"
                continue
            }
        esac

        _file=${KISS_ROOT:+"$KISS_ROOT/"}${file%%/}

        # Queue all directory symlinks for later removal.
        if [ -h "$_file" ] && [ -d "$_file" ]; then
            case $file in /*/*/)
                set -- "$@" "$_file"
            esac

        # Remove empty directories.
        elif [ -d "$_file" ]; then
            rmdir "$_file" 2>/dev/null || :

        # Remove everything else.
        else
            rm -f "$_file"
        fi
    done

    # Remove all broken directory symlinks.
    for sym do
        [ -e "$sym" ] || rm -f "$sym"
    done
}

pkg_etc() {
    sh256 "$tar_dir/$_pkg$file" "$KISS_ROOT$file" >/dev/null

    sum_new=${hash%%"$newline"*}
    sum_sys=${hash#*"$newline"}

    read -r sum_old <&3 2>/dev/null ||:

    # Compare the three checksums to determine what to do.
    case ${sum_old:-null}${sum_sys:-null}${sum_new} in
        # old = Y, sys = X, new = Y
        "${sum_new}${sum_sys}${sum_old}")
            return 1
        ;;

        # old = X, sys = X, new = X
        # old = X, sys = Y, new = Y
        # old = X, sys = X, new = Y
        "${sum_old}${sum_old}${sum_old}"|\
        "${sum_old:-null}${sum_sys}${sum_sys}"|\
        "${sum_sys}${sum_old}"*)

        ;;

        # All other cases.
        *)
            war "$_pkg" "saving $file as $file.new"
            _file=$_file.new
        ;;
    esac
}

pkg_removable() {
    # Check if a package is removable and die if it is not.
    # A package is removable when it has no dependents.
    log "$1" "Checking if package removable"

    cd "$sys_db"
    set +f

    ! grep -lFx -- "$1" */depends ||
        die "$1" "Not removable, has dependents"

    set -f
    cd "$OLDPWD"
}

pkg_remove() {
    # Remove a package and all of its files. The '/etc' directory is handled
    # differently and configuration files are *not* overwritten.
    [ -d "$sys_db/$1" ] || die "'$1' not installed"

    trap_off

    # Intended behavior.
    # shellcheck disable=2030,2031
    equ "$KISS_FORCE" 1  || pkg_removable "$1"

    # arg1: pre-remove
    # arg2: package name
    # arg3: path to installed database
    run_hook_pkg pre-remove "$1"
    run_hook     pre-remove "$1" "$sys_db/$1"

    # Make a backup of any etcsums if they exist.
    tmp_file_copy "$1" etcsums-copy "$sys_db/$1/etcsums"

    log "$1" "Removing package"
    pkg_remove_files < "$sys_db/$1/manifest" 3< "$_tmp_file"

    trap_on
    log "$1" "Removed successfully"
}

pkg_installable() {
    # Check if a package is removable and die if it is not.
    # A package is removable when all of its dependencies
    # are satisfied.
    log "$1" "Checking if package installable"

    # False positive.
    # shellcheck disable=2094
    ! [ -f "$2" ] ||

    while read -r dep dep_type || ok "$dep"; do
        case "$dep $dep_type" in [!\#]?*\ )
            ! [ -d "$sys_db/$dep" ] || continue

            printf '%s %s\n' "$dep" "$dep_type"

            set -- "$1" "$2" "$(($3 + 1))"
        esac
    done < "$2"

    case ${3:-0} in [1-9]*)
        die "$1" "Package not installable, missing $3 package(s)"
    esac
}

pkg_install() {
    # Install a built package tarball.
    #
    # Package installation works similarly to the method used by Slackware in
    # some of their tooling. It's not the obvious solution to the problem,
    # however it is the best solution at this given time.
    #
    # When an installation is an update to an existing package, instead of
    # removing the old version first we do something different.
    #
    # The new version is installed overwriting any files which it has in
    # common with the previously installed version of the package.
    #
    # A "diff" is then generated between the old and new versions and contains
    # any files existing in the old version but not the new version.
    #
    # The package manager then goes and removes these files which leaves us
    # with the new package version in the file system and all traces of the
    # old version gone.
    #
    # For good measure the package manager will then install the new package
    # an additional time. This is to ensure that the above diff didn't contain
    # anything incorrect.
    #
    # This is the better method as it is "seamless". An update to busybox won't
    # create a window in which there is no access to all of its utilities.

    # Install can also take the full path to a tarball. We don't need to check
    # the repository if this is the case.
    case $1 in
        *.tar.*)
            [ -f "$1" ] || die "File '$1' does not exist"

            tar_file=$1
            _pkg=${1##*/}
            _pkg=${_pkg%@*}
        ;;

        *)
            pkg_cache "$1" || die "$1" "Not yet built"
            _pkg=$1
        ;;
    esac

    trap_off
    mkcd "$tar_dir/$_pkg"

    # The tarball is extracted to a temporary directory where its contents are
    # then "installed" to the filesystem. Running this step as soon as possible
    # allows us to also check the validity of the tarball and bail out early
    # if needed.
    decompress "$tar_file" | tar xf -

    # Naively assume that the existence of a manifest file is all that
    # determines a valid KISS package from an invalid one. This should be a
    # fine assumption to make in 99.99% of cases.
    [ -f "$PWD/$pkg_db/$_pkg/manifest" ] || die "Not a valid KISS package"

    # Intended behavior.
    # shellcheck disable=2030,2031
    equ "$KISS_FORCE" 1 || {
        pkg_manifest_validate
        pkg_installable "$_pkg" "$PWD/$pkg_db/$_pkg/depends"
    }

    # arg1: pre-install
    # arg2: package name
    # arg3: path to extracted package
    run_hook pre-install "$_pkg" "$PWD"

    pkg_conflicts

    log "$_pkg" "Installing package (${tar_file##*/})"

    # If the package is already installed (and this is an upgrade) make a
    # backup of the manifest and etcsums files.
    tmp_file_copy "$_pkg" manifest-copy "$sys_db/$_pkg/manifest"
    tmp_file_copy "$_pkg"  etcsums-copy "$sys_db/$_pkg/etcsums"
    tmp_file      "$_pkg" manifest-diff

    tar_man=$PWD/$pkg_db/$_pkg/manifest

    # Generate a list of files which exist in the currently installed manifest
    # but not in the newer (to be installed) manifest.
    grep -vFxf "$tar_man" "$_tmp_file_pre_pre" > "$_tmp_file" 2>/dev/null ||:

    # Reverse the manifest file so that we start shallow and go deeper as we
    # iterate over each item. This is needed so that directories are created
    # going down the tree.
    tmp_file "$_pkg" manifest-reverse
    sort "$tar_man" > "$_tmp_file"

    if
        # Install the package's files by iterating over its manifest.
        pkg_install_files -z "$PWD" < "$_tmp_file" 3< "$_tmp_file_pre_pre" &&

        # This is the aforementioned step removing any files from the old
        # version of the package if the installation is an update. Each file
        # type has to be specially handled to ensure no system breakage occurs.
        pkg_remove_files < "$_tmp_file_pre" 3< "$_tmp_file_pre_pre" &&

        # Install the package's files a second time to fix any mess caused by
        # the above removal of the previous version of the package.
        pkg_install_files -e "$PWD" < "$_tmp_file" 3< "$_tmp_file_pre_pre"

    then
        trap_on

        # arg1: post-install
        # arg2: package name
        # arg3: path to installed package database
        run_hook_pkg post-install "$_pkg"
        run_hook     post-install "$_pkg" "$sys_db/$_pkg"

        log "$_pkg" "Installed successfully"

    else
        pkg_clean
        log "$_pkg" "Failed to install package." ERROR
        die "$_pkg" "Filesystem now dirty, manual repair needed."
    fi
}

pkg_update() {
    log "Updating repositories"

    # Create a list of all repositories.
    # Intentional, globbing disabled.
    # shellcheck disable=2046,2086
    { IFS=:; set -- $KISS_PATH; unset IFS; }

    # Update each repository in '$KISS_PATH'.
    for repo do
        if git -C "$repo" rev-parse 'HEAD@{upstream}' >/dev/null 2>&1; then
            repo_type=git

            # Get the Git repository root directory.
            subm=$(git -C "$repo" rev-parse --show-superproject-working-tree)
            repo=$(git -C "${subm:-"$repo"}" rev-parse --show-toplevel)

        elif ! [ -d "$repo" ]; then
            continue

        else
            unset repo_type
        fi

        pkg_update_repo
    done

    pkg_upgrade
}

pkg_update_repo() {
    cd "$repo" || die "Repository '$repo' inaccessible"

    contains "$repos" "$PWD" || {
        repos="$repos $PWD"

        log "$PWD" " "

        am_owner "$PWD" || {
            printf 'Need "%s" to update\n' "$user"
            set -- as_user
        }

        # arg1: pre-update
        # arg2: need su?
        # arg3: owner
        # env:  PWD is path to repository
        run_hook pre-update "$#" "$user"

        case $repo_type in git)
            pkg_update_git "$@"
        esac

        # arg1: post-update
        # env:  PWD is path to repository
        run_hook post-update
    }
}

pkg_update_git() {
    # Display whether or not signature verification is enabled.
    case $(git config --get merge.verifySignatures) in true)
        printf 'Signature verification enabled.\n'
    esac

    "$@" git pull
    "$@" git submodule update --remote --init -f
}

pkg_upgrade() {
    log "Checking for new package versions"
    set +f

    for pkg in "$sys_db/"*; do set -f
        pkg_find_version "${pkg##*/}" "" "" "$sys_db"
        pkg_find_version "${pkg##*/}"

        # Detect repository orphans (installed packages with no
        # associated repository).
        case $repo_dir in */var/db/kiss/installed/*)
            _repo_orp="$_repo_orp$newline${pkg##*/}"
        esac

        # Compare installed packages to repository packages.
        equ "$ver_pre-$rel_pre" "$repo_ver-$repo_rel" || {
            set -- "$@" "${pkg##*/}"

            printf '%s %s => %s\n' \
                "${pkg##*/}" "$ver_pre-$rel_pre" "$repo_ver-$repo_rel"
        }
    done

    case $_repo_orp in *?*)
        war "Packages without repository$_repo_orp"
    esac

    build_install=0
    prefer_cache=1

    ! contains "$*" kiss || {
        log "Detected package manager update"
        log "The package manager will be updated first"

        prompt
        pkg_build_all kiss

        log "Updated the package manager"
        log "Re-run 'kiss update' to update your system"
        return 0
    }

    for _ do
        pkg_order "$@"

        # Intentional, globbing disabled.
        # shellcheck disable=2046,2086
        set -- $order

        prompt "Packages to update ($#): $*"
        pkg_build_all "$@"
        log "Updated all packages"
        return 0
    done

    log "Nothing to do"
}

pkg_clean() {
    # Clean up on exit or error. This removes everything related to the build.
    # If _KISS_LVL is (1) we are the top-level process - the entire cache will
    # be removed. If _KISS_LVL is any other value, remove only the tar directory.
    case ${KISS_DEBUG:-0}-${_KISS_LVL:-1} in
        0-1) rm -rf "$proc" ;;
        0-*) rm -rf "$tar_dir"
    esac
}

pkg_help_ext() {
    log 'Installed extensions (kiss-* in PATH)'

    # Intentional, globbing disabled.
    # shellcheck disable=2046,2030,2031
    set -- $(pkg_find kiss-\* all -x "$PATH")

    # To align descriptions figure out which extension has the longest
    # name by doing a simple 'name > max ? name : max' on the basename
    # of the path with 'kiss-' stripped as well.
    #
    # This also removes any duplicates found in '$PATH', picking the
    # first match.
    for path do 
        p=${path#*/kiss-}

        case " $seen " in *" $p "*)
            shift
            continue
        esac

        seen=" $seen $p "
        max=$((${#p} > max ? ${#p}+1 : max))
    done

    # Print each extension, grab its description from the second line
    # in the file and align the output based on the above max.
    for path do
        # Open the extension as a file descriptor.
        exec 3< "$path"

        # Grab the second line in the extension.
        { read -r _ && IFS=\#$IFS read -r _ cmt; } <&3

        printf "%b->%b %-${max}s %s\\n" \
            "$c1" "$c3" "${path#*/kiss-}" "$cmt"
    done >&2
}

trap_on() {
    # Catch errors and ensure that build files and directories are cleaned
    # up before we die. This occurs on 'Ctrl+C' as well as success and error.
    trap trap_INT  INT
    trap trap_EXIT EXIT
}

trap_INT() {
    run_hook SIGINT
    exit 1
}

trap_EXIT() {
    pkg_clean
    run_hook SIGEXIT
}

trap_off() {
    # Block being able to abort the script with 'Ctrl+C'. Removes all risk of
    # the user aborting a package install/removal leaving an incomplete package
    # installed.
    trap "" INT EXIT
}

args() {
    # Parse script arguments manually. This is rather easy to do in our case
    # since the first argument is always an "action" and the arguments that
    # follow are all package names.
    action=$1
    shift "$(($# != 0))"

    # Ensure that arguments do not contain invalid characters. Wildcards can
    # not be used here as they would conflict with kiss extensions.
    case $action in
        a|alternatives)
            case $1 in *\**|*\!*|*\[*|*\ *|*\]*|*/*|*"$newline"*)
                die "Invalid argument: '!*[ ]/\\n' ($1)"
            esac
        ;;

        b|build|c|checksum|d|download|i|install|l|list|r|remove)
            for _arg do case ${action%%"${action#?}"}-$_arg in
                i-*\!*|i-*\**|i-*\[*|i-*\ *|i-*\]*|i-*"$newline"*)
                    die "Invalid argument: '!*[ ]\\n' ('$_arg')"
                ;;

                [!i]-*\!*|[!i]-*\**|[!i]-*\[*|[!i]-*\ *|\
                [!i]-*\]*|[!i]-*/*|[!i]-*"$newline"*)
                    die "Invalid argument: '!*[ ]/\\n' ('$_arg')"
                ;;
            esac done

            # When no arguments are given on the command-line, use the basename
            # of the current directory as the package name and add the parent
            # directory to the running process' KISS_PATH.
            case ${action%%"${action#?}"}-$# in [!l]-0)
                export KISS_PATH=${PWD%/*}:$KISS_PATH
                set -- "${PWD##*/}"
            esac

            # Search the installed database first when removing packages. Dependency
            # files may differ when repositories change. Removal is not dependent on
            # the state of the repository.
            case $action in r|remove)
                export KISS_PATH=$sys_db:$KISS_PATH
            esac

            # Order the argument list based on dependence.
            pkg_order "$@"

            # Intentional, globbing disabled.
            # shellcheck disable=2046,2086
            set -- $order
        ;;
    esac

    # Need to increment _KISS_LVL here to ensure we don't wipe the cache
    # early by non-asroot invocations.
    export _KISS_LVL=$((_KISS_LVL + 1))

    # Rerun the script as root with a fixed environment if needed. We sadly
    # can't run singular functions as root so this is needed.
    #
    # Intended behavior.
    # shellcheck disable=2030,2031
    case $action in a|alternatives|i|install|r|remove)
        if ok "$1" && ! am_owner "$KISS_ROOT/"; then
            trap_off

            as_user env \
                LOGNAME="$user" \
                HOME="$HOME" \
                XDG_CACHE_HOME="$XDG_CACHE_HOME" \
                KISS_COMPRESS="$KISS_COMPRESS" \
                KISS_PATH="$KISS_PATH" \
                KISS_FORCE="$KISS_FORCE" \
                KISS_ROOT="$KISS_ROOT" \
                KISS_CHOICE="$KISS_CHOICE" \
                KISS_COLOR="$KISS_COLOR" \
                KISS_TMPDIR="$KISS_TMPDIR" \
                KISS_PID="$KISS_PID" \
                _KISS_LVL="$_KISS_LVL" \
                "$0" "$action" "$@"

            trap_on
            return
        fi
    esac

    # Actions can be abbreviated to their first letter. This saves keystrokes
    # once you memorize the commands.
    case $action in
        a|alternatives) pkg_alternatives "$@" ;;
        b|build)        pkg_build_all "$@" ;;
        c|checksum)     for pkg do pkg_checksum "$pkg"; done ;;
        d|download)     for pkg do pkg_source "$pkg"; done ;;
        H|help-ext)     pkg_help_ext "$@" ;;
        i|install)      for pkg do pkg_install "$pkg"; done ;;
        l|list)         pkg_list_version "$@" ;;
        r|remove)       for pkg in $redro; do pkg_remove "$pkg"; done ;;
        s|search)       for pkg do pkg_find "$pkg" all; done ;;
        u|update)       pkg_update ;;
        U|upgrade)      pkg_upgrade ;;
        v|version)      printf '5.5.28\n' ;;

        '')
            log 'kiss [a|b|c|d|i|l|r|s|u|U|v] [pkg]...'
            log 'alternatives List and swap alternatives'
            log 'build        Build packages'
            log 'checksum     Generate checksums'
            log 'download     Download sources'
            log 'install      Install packages'
            log 'list         List installed packages'
            log 'remove       Remove packages'
            log 'search       Search for packages'
            log 'update       Update the system and repositories'
            log 'upgrade      Update the system'
            log 'version      Package manager version'

            printf '\nRun "kiss [H|help-ext]" to see all actions\n'
        ;;

        *)
            # _KISS_LVL must be reset here so the that any extensions
            # which call the package manager do not increment the value
            # further than the parent instance.
            pkg_find "kiss-$action*" "" -x "$PATH"
            _KISS_LVL=0 "$repo_dir" "$@"
        ;;
    esac
}

create_tmp_dirs() {
    # Root directory.
    KISS_ROOT=${KISS_ROOT%"${KISS_ROOT##*[!/]}"}

    # This allows for automatic setup of a KISS chroot and will
    # do nothing on a normal system.
    mkdir -p "$KISS_ROOT/" 2>/dev/null || :

    # System package database.
    sys_db=$KISS_ROOT/${pkg_db:=var/db/kiss/installed}
    sys_ch=$KISS_ROOT/${cho_db:=var/db/kiss/choices}

    # Top-level cache directory.
    cac_dir=${XDG_CACHE_HOME:-"${HOME%"${HOME##*[!/]}"}/.cache"}
    cac_dir=${cac_dir%"${cac_dir##*[!/]}"}/kiss

    # Persistent cache directories.
    src_dir=$cac_dir/sources
    log_dir=$cac_dir/logs/${time%-*}
    bin_dir=$cac_dir/bin

    # Top-level Temporary cache directory.
    proc=${KISS_TMPDIR:="$cac_dir/proc"}
    proc=${proc%"${proc##*[!/]}"}/$KISS_PID

    # Temporary cache directories.
    mak_dir=$proc/build
    pkg_dir=$proc/pkg
    tar_dir=$proc/extract
    tmp_dir=$proc/tmp

    mkdir -p "$src_dir" "$log_dir" "$bin_dir" \
             "$mak_dir" "$pkg_dir" "$tar_dir" "$tmp_dir"
}

main() {
    # Globally disable globbing and enable exit-on-error.
    set -ef

    # Color can be disabled via the environment variable KISS_COLOR. Colors are
    # also automatically disabled if output is being used in a pipe/redirection.
    equ "$KISS_COLOR" 0 || ! [ -t 2 ] || {
        c1='\033[1;33m'
        c2='\033[1;34m'
        c3='\033[m'
    }

    # Store the original working directory to ensure that relative paths
    # passed by the user on the command-line properly resolve to locations
    # in the filesystem.
    ppwd=$PWD

    # Never know when you're gonna need one of these.
    newline="
"

    # Defaults for environment variables.
    : "${KISS_COMPRESS:=gz}"
    : "${KISS_PID:=$$}"
    : "${LOGNAME:?POSIX requires LOGNAME be set}"

    # Figure out which 'sudo' command to use based on the user's choice or what
    # is available on the system.
    cmd_su=${KISS_SU:-"$(
        command -v ssu  ||
        command -v sudo ||
        command -v doas ||
        command -v su
    )"} || cmd_su=su

    # Figure out which utility is available to dump elf information.
    cmd_elf=${KISS_ELF:-"$(
        command -v readelf      ||
        command -v eu-readelf   ||
        command -v llvm-readelf
    )"} || cmd_elf=ldd

    # Figure out which sha256 utility is available.
    cmd_sha=${KISS_CHK:-"$(
        command -v openssl   ||
        command -v sha256sum ||
        command -v sha256    ||
        command -v shasum    ||
        command -v digest
    )"} || die "No sha256 utility found"

    # Figure out which download utility is available.
    cmd_get=${KISS_GET:-"$(
        command -v aria2c ||
        command -v axel   ||
        command -v curl   ||
        command -v wget   ||
        command -v wget2
    )"} || die "No download utility found (aria2c, axel, curl, wget, wget2)"

    # Store the date and time of script invocation to be used as the name of
    # the log files the package manager creates during builds.
    time=$(date +%Y-%m-%d-%H:%M)

    create_tmp_dirs
    trap_on

    args "$@"
}

main "$@"