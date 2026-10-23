# shellcheck shell=bash
# Filesystem ports: verify compiler products, retain complete trees and publish
# one coherent command set. No compiler or Nix invocation belongs in this file.

rb_main_name() {
	case "$1" in
		zig) printf randomz ;; rust) printf randomr ;; luajit) printf random ;;
		lean) printf randoml ;; roc) printf randomroc ;; bend) printf randomb ;;
		*) rb_error "no executable registered for '$1'" ;;
	esac
}

# Supported build hosts and formats are little-endian. Bound numeric fields
# before Bash arithmetic so malformed unsigned offsets cannot wrap negative.
rb_object_uint() {
	local value
	value="$(od -An -tu"$3" -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n')"
	case "$value" in ''|*[!0-9]*) rb_error 'truncated object header'; return 1 ;; esac
	[ "${#value}" -le 13 ] && [ "$value" -le 1099511627776 ] || {
		rb_error 'unreasonable object header offset/count'; return 1;
	}
	printf '%s' "$value"
}

rb_object_range() {
	[ "$1" -le "$3" ] && [ "$2" -le "$(($3 - $1))" ] || {
		rb_error 'truncated object data or out-of-file offset'; return 1;
	}
}

rb_verify_archive() {
	local listing
	listing="$(LC_ALL=C ar t "$1" 2>&1)" || { rb_error "invalid static archive $1: $listing"; return 1; }
	[ -n "$listing" ] || { rb_error "empty static archive: $1"; return 1; }
}

# Inspect actual headers independently of a directory name or build manifest.
rb_inspect_binary() {
	local binary="$1" pf="$2" variant="$3" magic machine format details pe_offset bytes
	[ -s "$binary" ] || { rb_error "missing binary: $binary"; return 1; }
	bytes="$(wc -c <"$binary" | tr -d ' \n')"
	magic="$(od -An -tx1 -N4 "$binary" | tr -d ' \n')" || return 1
	case "$pf" in
		linux-*)
			format="$(od -An -tx1 -j4 -N2 "$binary" | tr -d ' \n')"
			machine="$(od -An -tx1 -j18 -N2 "$binary" | tr -d ' \n')"
			case "$pf:$magic:$format:$machine" in
				linux-amd64:7f454c46:0201:3e00|linux-arm64:7f454c46:0201:b700) ;;
				*) rb_error "wrong ELF class/endianness/architecture for $pf: $binary"; return 1 ;;
			esac
			# Magic/CPU alone accepts a truncated 64-byte header. The independent
			# binutils reader must also accept its program and section tables.
			details="$(LC_ALL=C readelf -h -l -S -- "$binary" 2>&1 >/dev/null)"
			if [ "$?" -ne 0 ] || [ -n "$details" ]; then
				rb_error "invalid ELF structure in $binary: $details"; return 1
			fi
			details="$(LC_ALL=C file -b -- "$binary")" || return 1
			case "$variant:$details" in
				musl:*'dynamically linked'*)
					[[ "$details" == *ld-musl* ]] || { rb_error "non-musl loader in $binary"; return 1; } ;;
				gnu:*ld-musl*) rb_error "musl loader in GNU product $binary"; return 1 ;;
			esac
			;;
		macos-arm64)
			machine="$(od -An -tx1 -j4 -N4 "$binary" | tr -d ' \n')"
			[ "$magic:$machine" = cffaedfe:0c000001 ] || {
				rb_error "expected a thin arm64 Mach-O for $pf: $binary"; return 1;
			}
			local count extent offset=32 command command_size data_offset data_size index segments=0
			count="$(rb_object_uint "$binary" 16 4)" && extent="$(rb_object_uint "$binary" 20 4)" || return 1
			[ "$count" -gt 0 ] && [ "$count" -le 4096 ] || { rb_error 'invalid Mach-O load-command count'; return 1; }
			rb_object_range 32 "$extent" "$bytes" || return 1
			for ((index=0; index<count; index++)); do
				rb_object_range "$offset" 8 "$((32 + extent))" || return 1
				command="$(rb_object_uint "$binary" "$offset" 4)" && command_size="$(rb_object_uint "$binary" "$((offset + 4))" 4)" || return 1
				[ "$command_size" -ge 8 ] || { rb_error 'invalid Mach-O load-command size'; return 1; }
				rb_object_range "$offset" "$command_size" "$((32 + extent))" || return 1
				if [ "$command" -eq 25 ]; then
					[ "$command_size" -ge 72 ] || { rb_error 'short Mach-O segment command'; return 1; }
					data_offset="$(rb_object_uint "$binary" "$((offset + 40))" 8)" && data_size="$(rb_object_uint "$binary" "$((offset + 48))" 8)" || return 1
					rb_object_range "$data_offset" "$data_size" "$bytes" || return 1
					segments=$((segments + 1))
				fi
				offset=$((offset + command_size))
			done
			[ "$offset" -eq "$((32 + extent))" ] && [ "$segments" -gt 0 ] || { rb_error 'incomplete Mach-O load commands'; return 1; }
			;;
		mswin-*)
			[ "${magic:0:4}" = 4d5a ] || { rb_error "expected PE executable for $pf: $binary"; return 1; }
			pe_offset="$(od -An -tu4 -j60 -N4 "$binary" | tr -d ' \n')"
			case "$pe_offset" in ''|*[!0-9]*) rb_error "invalid PE offset in $binary"; return 1 ;; esac
			[ "$pe_offset" -le 16777216 ] || { rb_error "unreasonable PE header offset in $binary"; return 1; }
			format="$(od -An -tx1 -j "$pe_offset" -N4 "$binary" | tr -d ' \n')"
			machine="$(od -An -tx1 -j "$((pe_offset + 4))" -N2 "$binary" | tr -d ' \n')"
			case "$pf:$format:$machine" in
				mswin-amd64:50450000:6486|mswin-arm64:50450000:64aa) ;;
				*) rb_error "wrong PE architecture for $pf: $binary"; return 1 ;;
			esac
			local sections optional_size section raw_size raw_offset index
			sections="$(rb_object_uint "$binary" "$((pe_offset + 6))" 2)" && optional_size="$(rb_object_uint "$binary" "$((pe_offset + 20))" 2)" || return 1
			[ "$sections" -gt 0 ] && [ "$sections" -le 4096 ] && [ "$optional_size" -ge 112 ] || { rb_error 'invalid PE optional/section headers'; return 1; }
			section=$((pe_offset + 24 + optional_size))
			rb_object_range "$section" "$((sections * 40))" "$bytes" || return 1
			for ((index=0; index<sections; index++)); do
				raw_size="$(rb_object_uint "$binary" "$((section + 16))" 4)" && raw_offset="$(rb_object_uint "$binary" "$((section + 20))" 4)" || return 1
				rb_object_range "$raw_offset" "$raw_size" "$bytes" || return 1
				section=$((section + 40))
			done
			;;
		*) rb_error "no binary verifier for '$pf'"; return 1 ;;
	esac
}

rb_verify_product() {
	local product="$1" impl="$2" pf="$3" variant="$4" triple="$5" main suffix= name
	main="$(rb_main_name "$impl")" || return 1
	[[ "$pf" != mswin-* ]] || suffix=.exe
	for name in "$main" "n$main" "d$main"; do
		[ -x "$product/bin/$name$suffix" ] || { rb_error "required command missing: $product/bin/$name$suffix ($triple)"; return 1; }
	done
	if [ "$impl" = zig ]; then
		for name in "$main" "n$main" "d$main"; do
			rb_inspect_binary "$product/bin/$name$suffix" "$pf" "$variant" || return 1
		done
		local static=lib/librandomz.a
		[[ "$pf" != mswin-* ]] || static=lib/randomz.lib
		[ -s "$product/$static" ] && [ -s "$product/include/randomz.h" ] || {
			rb_error "Zig product is incomplete: need $static and include/randomz.h"; return 1;
		}
		rb_verify_archive "$product/$static" || return 1
	elif [ "$impl" != luajit ]; then
		# Nix may wrap only the self-test I/O environment. Inspect the real
		# executable, not that shell launcher or its producer-written metadata.
		local native="$product/bin/$main$suffix"
		if [ -s "$product/libexec/$main$suffix" ]; then native="$product/libexec/$main$suffix"
		elif [ -s "$product/bin/.$main-wrapped" ]; then native="$product/bin/.$main-wrapped"; fi
		rb_inspect_binary "$native" "$pf" "$variant" || return 1
	else
		# Packaged interpreted/self-test launchers keep their existing runtime
		# wrappers. Their own installed-consumer/CLI gates validate those graphs.
		[ -d "$product/lib" ] || {
			rb_error 'LuaJIT product has no adjacent library modules'; return 1;
		}
	fi
}

# Link two project-local paths relatively. The target may itself be a retained
# Nix output link; never resolve it into an unrooted copied store pathname.
rb_link_relative() {
	local root="$1" target="$2" link="$3" parent relative up= part
	case "$target" in "$root"/*) ;; *) rb_error "link target is outside the project: $target"; return 1 ;; esac
	case "$link" in "$root"/*) ;; *) rb_error "link destination is outside the project: $link"; return 1 ;; esac
	parent="${link%/*}"
	relative="${parent#"$root"/}"
	if [ "$parent" != "$root" ]; then
		local parts
		IFS=/ read -r -a parts <<<"$relative"
		for part in "${parts[@]}"; do up="../$up"; done
	fi
	ln -s -- "$up${target#"$root"/}" "$link"
}

# GNU mv needs -T and BSD mv needs -h to replace a directory symlink rather
# than follow it. Both perform a same-directory rename, not a tree copy.
rb_replace_link() {
	local temporary="$1" destination="$2"
	if mv --version >/dev/null 2>&1; then
		mv -fT -- "$temporary" "$destination"
	else
		mv -fh -- "$temporary" "$destination"
	fi
}

rb_select_product() {
	local root="$1" request="$2" product="$3" impl pf variant profile triple parent temporary
	IFS='|' read -r impl pf variant profile triple <<<"$request"
	parent="$root/$impl-out/$pf"
	[ -z "$variant" ] || parent="$parent/$variant"
	mkdir -p "$parent" || return 1
	temporary="$parent/.selection.$RB_GENERATION"
	rb_link_relative "$root" "$product" "$temporary" || return 1
	if [ -e "$parent/$profile" ] && [ ! -L "$parent/$profile" ]; then
		rb_error "unmanaged product directory exists: $parent/$profile; preserve it before adopting this path"
		return 1
	fi
	rb_replace_link "$temporary" "$parent/$profile"
}

rb_managed_name() {
	local name="$1" list="$2" known
	while IFS= read -r known; do [ "$known" != "$name" ] || return 0; done <"$list"
	return 1
}

rb_prepare_publication() {
	local root="$1" product="$2" impl="$3" pf="$4" mode="$5" stage="$6"
	local native suffix= entry name resource old="" main
	main="$(rb_main_name "$impl")" || return 1
	[[ "$pf" != mswin-* ]] || suffix=.exe
	printf 'random-publication-v1\n%s\n%s\n' "$impl" "$product" >"$stage/.random-publication"
	printf '%s\n' .random-publication .random-managed >"$stage/.random-managed"
	for entry in "$product/bin/"*; do
		[ -e "$entry" ] || [ -L "$entry" ] || continue
		name="${entry##*/}"
		case "$name" in
			"$main$suffix"|"n$main$suffix"|"d$main$suffix"|*.dll|*.DLL|*.pdb|*.manifest|*.config) ;;
			*) continue ;; # Diagnostic drivers/WASM remain in the product, not PATH.
		esac
		if [ "$mode" = copy ]; then cp -LR -- "$entry" "$stage/$name" || return 1
		else rb_link_relative "$root" "$entry" "$stage/$name" || return 1; fi
		printf '%s\n' "$name" >>"$stage/.random-managed"
	done
	for name in random nrandom drandom; do
		[ ! -e "$stage/$name$suffix" ] || continue
		case "$name" in random) native="$main" ;; nrandom) native="n$main" ;; drandom) native="d$main" ;; esac
		if [ "$mode" = copy ]; then cp -L -- "$product/bin/$native$suffix" "$stage/$name$suffix" || return 1
		else rb_link_relative "$root" "$product/bin/$native$suffix" "$stage/$name$suffix" || return 1; fi
		printf '%s\n' "$name$suffix" >>"$stage/.random-managed"
	done
	for resource in lib include share tests libexec; do
		[ -e "$product/$resource" ] || continue
		if [ "$mode" = copy ]; then cp -LR -- "$product/$resource" "$stage/$resource" || return 1
		else rb_link_relative "$root" "$product/$resource" "$stage/$resource" || return 1; fi
		printf '%s\n' "$resource" >>"$stage/.random-managed"
	done
	if [ -e "$root/bin/$pf" ] || [ -L "$root/bin/$pf" ]; then
		old="$(cd -P "$root/bin/$pf" && pwd)" || return 1
		[ -f "$old/.random-publication" ] && [ -f "$old/.random-managed" ] || {
			rb_error "unmanaged bin/$pf exists; refusing to replace or delete its contents"; return 1;
		}
		for entry in "$old/"* "$old/".[!.]* "$old/"..?*; do
			[ -e "$entry" ] || [ -L "$entry" ] || continue
			name="${entry##*/}"
			rb_managed_name "$name" "$old/.random-managed" && continue
			if [ -e "$stage/$name" ] || [ -L "$stage/$name" ]; then
				rb_error "unmanaged command '$name' conflicts with the new product"; return 1
			fi
			if [ "$mode" = copy ]; then cp -LR -- "$entry" "$stage/$name" || return 1
			else rb_link_relative "$root" "$entry" "$stage/$name" || return 1; fi
		done
	fi
}

# A publication holds the same lock as canonization: a selector cannot change
# between validation and commit. A failed stage never retargets a working set.
rb_publish() (
	local root="$1" canonical="$2" request="$3" product="$4" mode="${5:-link}"
	local impl pf variant profile triple stage temporary old_backup= status=0
	IFS='|' read -r impl pf variant profile triple <<<"$request"
	[ "$impl" = "$canonical" ] || { rb_error 'only the canonical implementation may publish commands'; return 1; }
	rb_known_platform "$pf" || return 1
	case "$mode" in link|copy) ;; *) rb_error 'unknown publication adapter'; return 1 ;; esac
	rb_lock "$root" selection || return 1
	trap 'rb_unlock "$root" selection' EXIT
	[ "$(rb_read_selection "$root")" = "$canonical" ] || { rb_error 'canonical implementation changed during the build; rerun ./build'; return 1; }
	rb_verify_product "$product" "$impl" "$pf" "$variant" "$triple" || return 1
	mkdir -p "$root/bin" "$root/.build-work/publications/$pf" || return 1
	stage="$(mktemp -d "$root/.build-work/publications/$pf/set.XXXXXX")" || return 1
	rb_prepare_publication "$root" "$product" "$impl" "$pf" "$mode" "$stage" || return 1
	if [ "$mode" = link ]; then
		if [ -e "$root/bin/$pf" ] && [ ! -L "$root/bin/$pf" ]; then
			rb_error "bin/$pf is an ordinary directory; refusing an unreviewed migration"; return 1
		fi
		temporary="$root/bin/.${pf}.${stage##*/}"
		rb_link_relative "$root" "$stage" "$temporary" || return 1
		rb_replace_link "$temporary" "$root/bin/$pf" || return 1
	else
		# Native Windows can launch these ordinary .exe files without Bash or
		# symlink privileges. Directory rotation retains a recoverable old set.
		if [ -e "$root/bin/$pf" ] || [ -L "$root/bin/$pf" ]; then
			old_backup="$root/.build-work/publications/$pf/previous.${stage##*/}"
			mv -- "$root/bin/$pf" "$old_backup" || return 1
		fi
		if ! mv -- "$stage" "$root/bin/$pf"; then
			[ -z "$old_backup" ] || mv -- "$old_backup" "$root/bin/$pf"
			return 1
		fi
		stage="$root/bin/$pf"
	fi
	printf '%s\n' "$stage"
)
