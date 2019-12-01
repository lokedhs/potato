#!/bin/sh

deps="librabbitmq-dev libfixposix-dev openjdk-8-jdk libffi-dev gcc g++ nodejs nodejs-legacy npm imagemagick couchdb rabbitmq-server memcached wget"

potato_root=`pwd`

fail () {
    if [ $# -ge 1 ] ; then
        echo "$1"
    fi
    exit 1
}

check_deps_ubuntu () {
    for package in $deps ; do
	if ! (dpkg -s $package | egrep '^Status:.*installed' >/dev/null 2>&1) ; then
	    echo $package
	fi
    done
}

ensure_deps_ubuntu () {
    required=`check_deps_ubuntu`
    if [ ! -z "$required" ] ; then
	echo "The following packages needs to be installed:"
	echo
	for package in $required ; do
	    echo "    $package"
	done
	echo
	echo "Press <RETURN> to run the appropriate command to install the"
	echo "packages (which will ask for your password in order to run"
	echo "sudo). Or exit this script and install the packages manually"
	echo "and then run this script again."
	echo -n "press return>"
	read foo
		
	sudo apt-get install $required || fail "Failed to install packages"
    fi
}

in_path () {
    file=$1
    for x in `echo "$PATH" | tr ':' '\n'` ; do
	if [ -x $x/$file ] ; then
	    return 0
	fi
    done
    return 1
}

if [ ! -f potato.asd ] ; then
    echo "This script should be run from the root of the source tree."
    exit 1
fi

if ! in_path apt-get ; then
    echo "This script currently only works on Ubuntu."
    echo "You can still set up a development environment manually by"
    echo "following the instructions in docs/INSTALL.md"
    exit 1
fi

ensure_deps_ubuntu

if ! (sbcl --non-interactive --quit --eval '(sb-ext:exit :code 0)' >/dev/null 2>&1) ; then
    echo "SBCL is not installed, or not available in the PATH"
    exit 1
fi

if ! (sbcl --non-interactive --quit --eval '(sb-ext:exit :code (if (find-package "QL") 0 1))' >/dev/null 2>&1) ; then
    echo "Quicklisp is not installed. Please follow the instructions at"
    echo "https://www.quicklisp.org/beta/"
    exit 1
fi

git submodule init || fail "Failed to init submodules"
git submodule update || fail "Failed to update git submodules"

if [ ! -x potato.bin ] ; then
    tools/build_binary.sh || fail "Failed to build binary"
fi

lein_path=lein
if ! ($lein_path >/dev/null 2>&1) ; then
    echo "Lein installation not found. It will be downloaded into the current"
    echo "directory. It is recommended that you copy it to somewhere in PATH."
    if [ ! -x lein ] ; then
	wget -q 'https://raw.githubusercontent.com/technomancy/leiningen/stable/bin/lein' || fail "Failed to download lein"
	chmod +x lein
	./lein || fail "Failed to install lein"
    fi
    lein_path=`pwd`/lein
fi

if [ ! -f web-app/resources/public/js/potato.js ] ; then
    (
	cd web-app
	$lein_path with-profile -dev cljsbuild once prod admin-prod
    )
fi

if [ ! -d public ] ; then
    (
        cd web-app
        ./make.sh || fail "Error building resources"
    )
fi

if [ ! -f init-potato.lisp ] ; then
	cat >init-potato.lisp <<EOF
(let ((potato-root #p"$potato_root/"))
  (push potato-root asdf:*central-registry*)
  (setf asdf:*central-registry*
        (append (mapcar (lambda (v)
                          (merge-pathnames v (merge-pathnames #p"vendor/"
                                                              potato-root)))
                        '(#p"cl-markup/"
                          #p"clouchdb-patch/src/"
                          #p"cl-rabbit/"
                          #p"cl-rabbit-async/"
                          #p"cl-solr/"
                          #p"containers/"
                          #p"html5-notification/"
                          #p"lofn/"))
                asdf:*central-registry*)))

(ql:quickload "potato")

(defun potato-run ()
  ;;(setq potato.common:*db-user* "user")
  ;;(setq potato.common:*db-password* "password")
  (potato:start-server-debug))
EOF
fi

echo
echo "Development environment has been set up."
echo "In order to load the system into a running SBCL instance,"
echo "load the file init-potato.lisp. This loads all dependencies"
echo "and defines a function potato-run that can be used to start"
echo "the application. By default, a local installation runs on"
echo "port 8080."
echo
echo "In order to set up a basic test configuration (domain, channel,"
echo "user, etc...) run the function potato:init-dev-db from the REPL."
