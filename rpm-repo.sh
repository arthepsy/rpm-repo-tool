#!/bin/sh
_cdir=$(cd -- "$(dirname "$0")" && pwd)
_err() { echo "err: $1" >&2 && exit 1; }
cd -- "${_cdir}" || exit 1

_usage() {
	printf "# rpm-repo.sh v1.0.0, moo@arthepsy.eu\n\n"                       >&2
	printf "usage: %s [ -c rpm-repo.conf ] <command> [<args>]\n\n" "$0"      >&2
	printf "Commands:\n"                                                     >&2
	printf "  gpg-import [URI]   Import keys from configured repos or URI\n" >&2
	printf "  gpg-list           Display imported keys\n"                    >&2
	printf "  gpg-remove KEY     Remove imported KEY\n"                      >&2
	printf "  list               Display configured repositories\n"          >&2
	printf "  run COMMAND        Runs (rpmdb) wrapped COMMAND\n"             >&2
	printf "  sync [REPO]        Synchronizes repository/-ies\n"             >&2
	echo; exit 1
}

_main() {
	case "$1" in
		list) shift; _cmd_run yum -C repolist all ;;
		run) shift; _cmd_run "$@" ;;
		sync) shift; _cmd_sync "$@" ;;
		gpg-*) _cmd_gpg "$@" ;;
		*) _usage ;;
	esac
}

_read_cv() {
	_file="${_conf}"; [ -n "$2" ] && _file="$2"
	_o=$(grep "^$1 *=" "${_file}" | cut -d '=' -f 2- | _strip)
	[ -z "${_o}" ] && exit 1 || echo "${_o}"
}

_read_rv() {
	sed -nr "/^\[$2\]/,/\[/{/$3/s/^[^=]*= *(.*) *$/\1/p;}" "$1" | _strip
}

_read_conf() {
	_conf=${RPM_REPO_CONF:-rpm-repo.conf}
	if [ X"$1" = X"-c" ]; then
		shift; _conf="$1"; shift
	fi
	[ ! -r "${_conf}" ] && _err "failed to read configuration file: ${_conf}"
	_yuver=$(_read_cv "yum-utils")  || _err "yum-utils version not configured."
	_yumconf=$(_read_cv "yum-conf") || _err "yum-conf version not configured."
	_rpmdb=$(_read_cv "rpmdb")      || _err "rpmdb version not configured."
	_destdir=$(_read_cv "destdir")  || _err "destdir not configured."
	
	_destdir=$(echo "${_destdir}" | sed 's#/*$##')
	_rpmdb=$(echo "${_rpmdb}" | sed 's#/*$##')
}

_check_requirements() {
	[ ! -d "${_rpmdb}" ] && mkdir -p -- "${_rpmdb}" >/dev/null 2>&1
	_rpmdb=$(cd -- "${_rpmdb}" && pwd) || _err "rpmdb does not exist."
	
	_fetch=$(_get_fetch) || _err "no download utility (fetch/curl/wget) found."
	_py2=$(_get_py2) || _err "python not available."
	_gzipd=$(_get_gzipd) || _err "gzip not available."
	_cmd_run rpm --version >/dev/null 2>&1 || _err "rpm not available."
	_cmd_run yum --version >/dev/null 2>&1 || _err "yum not available."
	createrepo --version >/dev/null 2>&1 || _err "createrepo not available."
	modifyrepo --version >/dev/null 2>&1 || _err "modifyrepo not available."
	_ensure_yumutils || _err "yum-utils not available."
}

_ensure_yumutils() {
	_yufn="yum-utils-${_yuver}"
	[ -d "${_yufn}" ] && return 0
	if [ ! -f "${_yufn}.tar.gz" ]; then
		_url="http://yum.baseurl.org/download/yum-utils/${_yufn}.tar.gz"
		echo "[info] downloading ${_url}" >&2
		${_fetch} "${_yufn}.tar.gz" "${_url}" || _err "download failed: ${_url}"
	fi
	if [ ! -d "${_yufn}" ]; then
		echo "[info] extracting ${_yufn}" >&2
		tar -xzf "${_yufn}.tar.gz" || _err "yum-utils extraction failed."
	fi
	[ ! -d "${_yufn}" ] && return 1
	echo "[info] patching ${_yufn}" >&2
	_yum=$(command -v yum 2>/dev/null) || _err "yum not available."
	_yumcli=$(grep "sys.path" "${_yum}" | sed -e "s#'#\"#g" | cut -d '"' -f 2)
	[ -z "${_yumcli}" ] && _err "cannot find yum-cli path."
	find "${_yufn}" -type f -name "*.py" -exec \
		grep -q '/usr/share/yum-cli' -- "{}" \; -exec \
		sed -i "" -e "s#/usr/share/yum-cli#${_yumcli}#g" -- "{}" \;
}

_get_fetch() {
	command -v fetch2 >/dev/null 2>&1 && echo "fetch -q -o " && return 0
	command -v wget2  >/dev/null 2>&1 && echo "wget -q -O "  && return 0
	command -v curl   >/dev/null 2>&1 && echo "curl -s -o "  && return 0
	return 1
}

_get_gzipd() {
	command -v gunzip >/dev/null 2>&1 && echo "gunzip -d " && return 0
	command -v gzip >/dev/null 2>&1   && echo "gzip -d "   && return 0
	return 1
}

_get_py2() {
	for py in "python2.7" "python2" "python"; do
		command -v "${py}" >/dev/null 2>&1 && echo "${py}" && return 0
	done
	return 1
}

_strip() { sed 's/^[ \t]*//;s/[ \t]*$//'; }

_split() {
	_line=$1; IFS=$2; shift 2
	read -r -- "$@" _ <<-EOF
		${_line}
	EOF
}

_get_repo_names() {
	find "$(_read_cv "reposdir" "${_yumconf}")" -type f -name "*.repo" -exec \
		sed -ne 's#^\[\(.*\)\]$#{}|\1#p' {} \;
}

_cmd_gpg() {
	case "$1" in
		gpg-import)
			(set -f; IFS='
			'
			for _repo_names_line in $(_get_repo_names); do
				_repof=""; _repon=""
				_split "${_repo_names_line}" '|' _repof _repon
				_enabled=$(_read_rv "${_repof}" "${_repon}" "enabled")
				_gpgcheck=$(_read_rv "${_repof}" "${_repon}" "gpgcheck")
				[ X"${_enabled}${_gpgcheck}" != X"11" ] && continue
				_gpgkey=$(_read_rv "${_repof}" "${_repon}" "gpgkey")
				[ -z "${_gpgkey}" ] && continue
				echo "[info] importing ${_repon} gpgkey: ${_gpgkey}" >&2
				_cmd_run rpm --import "${_gpgkey}" || \
					_err "failed to import gpgkey: ${_gpgkey}"
			done
			)
			;;
		gpg-list)
			_fmt="%{version}-%{release} %{summary}\n"
			_cmd_run rpm -qa gpg-pubkey\* --qf "${_fmt}"
			;;
		gpg-remove)
			shift
			[ -z "$1" ] && _usage
			_cmd_run rpm -e "gpg-pubkey-$1" --allmatches
			;;
		*) _usage ;;
	esac
}

_cmd_run() {
	_cmd="$1"; shift
	case "${_cmd}" in 
		"") _usage ;;
		rpm2*) ${_cmd}; return $? ;;
		rpm*) ${_cmd} --dbpath="${_rpmdb}" "$@"; return $? ;;
		yum) 
			_cmd=$(command -v "${_cmd}" 2>/dev/null)
			_args="-c ${_yumconf}"
			_cachedir=$(_read_cv "cachedir" "${_yumconf}")
			if [ -n "${_cachedir}" ]; then
				_args="${_args} --setopt=cachedir=\"${_cachedir}\""
			fi
			eval "set -- ${_args} $*"
			;;
	esac
	${_py2} - "$@" \
	<<-EOF
		import io, os, sys
		if os.path.isabs("${_cmd}"):
		    _cmd="${_cmd}"
		else:
		    _cmd=os.path.join("yum-utils-${_yuver}", "${_cmd}.py")
		sys.argv[0] = _cmd
		if not os.path.isfile(_cmd):
		    print("err: command ${_cmd} not found.")
		    sys.exit(1)
		import rpm, urlgrabber
		rpm.addMacro('_dbpath', '${_rpmdb}')
		urlgrabber.grabber.URLGrabberOptions.user_agent = 'urlgrabber/3.10.2'
		execfile(_cmd)
		rpm.delMacro('_dbpath')
	EOF
}

_cmd_sync() {
	_args_sync="x --config=${_yumconf}"
	_args_sync="${_args_sync} --delete"
	_args_sync="${_args_sync} --downloadcomps"
	_args_sync="${_args_sync} --download-metadata"
	_args_sync="${_args_sync} --gpgcheck"
	_args_sync="${_args_sync} --plugins"
	
	_cachedir=$(_read_cv "cachedir" "${_yumconf}")
	if [ -n "${_cachedir}" ]; then
		_args_sync="${_args_sync} --cachedir=\"${_cachedir}\""
	fi
	
	(set -f; IFS='
	'
	_repo="$1"
	_destdirs=""
	for _repo_names_line in $(_get_repo_names); do
		_repof=""; _repon=""
		_split "${_repo_names_line}" '|' _repof _repon
		[ -n "${_repo}" ] && [ X"${_repo}" != X"${_repon}" ] && continue
		_enabled=$(_read_rv "${_repof}" "${_repon}" "enabled")
		[ X"${_enabled}" != X"1" ] && continue
		echo "[info] synchronizing remote repository: ${_repon}"
		_args="${_args_sync} --repoid=${_repon} --norepopath"
		_sync_destdir=$(_read_rv "${_repof}" "${_repon}" "_sync.destdir")
		if [ -n "${_sync_destdir}" ]; then
			_repo_destdir="${_sync_destdir}"
			echo "${_sync_destdir}" | grep -q '^/' || \
				_repo_destdir="${_destdir}/${_repo_destdir}"
		else
			_repo_destdir="${_destdir}/${_repon}"
		fi
		_destdirs="${_destdirs}${_repo_destdir}\n"
		_args="${_args} --download_path=\"${_repo_destdir}\""
		_repo_newest=$(_read_rv "${_repof}" "${_repon}" "_sync.newest-only")
		[ X"${_repo_newest}" != X"1" ] && _args="${_args} --newest-only"
		eval "set -- $_args"
		_cmd_run reposync "$@"
	done
	
	set -f; IFS='
	'
	for _repo_destdir in $(printf "%b" "${_destdirs}" | sort -u); do
		set +f
		echo "[info] updating local repository: ${_repo_destdir}"
		cd -- "${_cdir}" || continue
		cd -- "${_repo_destdir}" || continue
		_args="-v --pretty --workers 2"
		[ -f comps.xml ] && _args="${_args} -g comps.xml"
		pwd | grep -q ' ' || _args="${_args} --update"
		eval "set -- $_args ."
		createrepo "$@"
		for _updateinfo in ./*-updateinfo.xml.gz; do
			if [ -e "${_updateinfo}" ]; then
				${_gzipd} ./*-updateinfo.xml.gz
				modifyrepo updateinfo.xml repodata
				break
			fi
		done
	done
	)
	set -- 
}

_read_conf "$@" && _check_requirements && _main "$@"
