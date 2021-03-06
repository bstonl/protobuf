#!/bin/bash
#
# Build and runs tests for the protobuf project.  The tests as written here are
# used by both Jenkins and Travis, though some specialized logic is required to
# handle the differences between them.

on_travis() {
  if [ "$TRAVIS" == "true" ]; then
    "$@"
  fi
}

# For when some other test needs the C++ main build, including protoc and
# libprotobuf.
internal_build_cpp() {
  if [ -f src/protoc ]; then
    # Already built.
    return
  fi

  if [[ $(uname -s) == "Linux" && "$TRAVIS" == "true" ]]; then
    # Install GCC 4.8 to replace the default GCC 4.6. We need 4.8 for more
    # decent C++ 11 support in order to compile conformance tests.
    sudo add-apt-repository ppa:ubuntu-toolchain-r/test -y
    sudo apt-get update -qq
    sudo apt-get install -qq g++-4.8
    export CXX="g++-4.8" CC="gcc-4.8"
  fi

  ./autogen.sh
  ./configure
  make -j2
}

build_cpp() {
  internal_build_cpp
  make check -j2
  cd conformance && make test_cpp && cd ..

  # Verify benchmarking code can build successfully.
  cd benchmarks && make && ./generate-datasets && cd ..
}

build_cpp_distcheck() {
  ./autogen.sh
  ./configure
  make distcheck -j2
}

build_csharp() {
  # Just for the conformance tests. We don't currently
  # need to really build protoc, but it's simplest to keep with the
  # conventions of the other builds.
  internal_build_cpp
  NUGET=/usr/local/bin/nuget.exe

  if [ "$TRAVIS" == "true" ]; then
    # Install latest version of Mono
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF
    sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 1397BC53640DB551
    echo "deb http://download.mono-project.com/repo/debian wheezy main" | sudo tee /etc/apt/sources.list.d/mono-xamarin.list
    sudo apt-get update -qq
    sudo apt-get install -qq mono-devel referenceassemblies-pcl nunit
    
    # Then install the dotnet SDK as per Ubuntu 14.04 instructions on dot.net.
    sudo sh -c 'echo "deb [arch=amd64] https://apt-mo.trafficmanager.net/repos/dotnet/ trusty main" > /etc/apt/sources.list.d/dotnetdev.list'
    sudo apt-key adv --keyserver apt-mo.trafficmanager.net --recv-keys 417A0893
    sudo apt-get update -qq
    sudo apt-get install -qq dotnet-dev-1.0.0-preview2-003121
  fi

  # Perform "dotnet new" once to get the setup preprocessing out of the
  # way. That spews a lot of output (including backspaces) into logs
  # otherwise, and can cause problems. It doesn't matter if this step
  # is performed multiple times; it's cheap after the first time anyway.
  mkdir dotnettmp
  (cd dotnettmp; dotnet new > /dev/null)
  rm -rf dotnettmp

  (cd csharp/src; dotnet restore)
  csharp/buildall.sh
  cd conformance && make test_csharp && cd ..
}

build_golang() {
  # Go build needs `protoc`.
  internal_build_cpp
  # Add protoc to the path so that the examples build finds it.
  export PATH="`pwd`/src:$PATH"

  # Install Go and the Go protobuf compiler plugin.
  sudo apt-get update -qq
  sudo apt-get install -qq golang
  export GOPATH="$HOME/gocode"
  mkdir -p "$GOPATH/src/github.com/google"
  ln -s "`pwd`" "$GOPATH/src/github.com/google/protobuf"
  export PATH="$GOPATH/bin:$PATH"
  go get github.com/golang/protobuf/protoc-gen-go

  cd examples && make gotest && cd ..
}

use_java() {
  version=$1
  case "$version" in
    jdk6)
      on_travis sudo apt-get install openjdk-6-jdk
      export PATH=/usr/lib/jvm/java-6-openjdk-amd64/bin:$PATH
      ;;
    jdk7)
      on_travis sudo apt-get install openjdk-7-jdk
      export PATH=/usr/lib/jvm/java-7-openjdk-amd64/bin:$PATH
      ;;
    oracle7)
      if [ "$TRAVIS" == "true" ]; then
        sudo apt-get install python-software-properties # for apt-add-repository
        echo "oracle-java7-installer shared/accepted-oracle-license-v1-1 select true" | \
          sudo debconf-set-selections
        yes | sudo apt-add-repository ppa:webupd8team/java
        yes | sudo apt-get install oracle-java7-installer
      fi;
      export PATH=/usr/lib/jvm/java-7-oracle/bin:$PATH
      ;;
  esac

  if [ "$TRAVIS" != "true" ]; then
    MAVEN_LOCAL_REPOSITORY=/var/maven_local_repository
    MVN="$MVN -e -X --offline -Dmaven.repo.local=$MAVEN_LOCAL_REPOSITORY"
  fi;

  which java
  java -version
}

# --batch-mode supresses download progress output that spams the logs.
MVN="mvn --batch-mode"

build_java() {
  version=$1
  dir=java_$version
  # Java build needs `protoc`.
  internal_build_cpp
  cp -r java $dir
  cd $dir && $MVN clean && $MVN test
  cd ../..
}

# The conformance tests are hard-coded to work with the $ROOT/java directory.
# So this can't run in parallel with two different sets of tests.
build_java_with_conformance_tests() {
  # Java build needs `protoc`.
  internal_build_cpp
  cd java && $MVN test && $MVN install
  cd util && $MVN package assembly:single
  cd ../..
  cd conformance && make test_java && cd ..
}

build_javanano() {
  # Java build needs `protoc`.
  internal_build_cpp
  cd javanano && $MVN test && cd ..
}

build_java_jdk6() {
  use_java jdk6
  build_java jdk6
}
build_java_jdk7() {
  use_java jdk7
  build_java_with_conformance_tests
}
build_java_oracle7() {
  use_java oracle7
  build_java oracle7
}

build_javanano_jdk6() {
  use_java jdk6
  build_javanano
}
build_javanano_jdk7() {
  use_java jdk7
  build_javanano
}
build_javanano_oracle7() {
  use_java oracle7
  build_javanano
}

internal_install_python_deps() {
  if [ "$TRAVIS" != "true" ]; then
    return;
  fi
  # Install tox (OS X doesn't have pip).
  if [ $(uname -s) == "Darwin" ]; then
    sudo easy_install tox
  else
    sudo pip install tox
  fi
  # Only install Python2.6/3.x on Linux.
  if [ $(uname -s) == "Linux" ]; then
    sudo apt-get install -y python-software-properties # for apt-add-repository
    sudo apt-add-repository -y ppa:fkrull/deadsnakes
    sudo apt-get update -qq
    sudo apt-get install -y python2.6 python2.6-dev
    sudo apt-get install -y python3.3 python3.3-dev
    sudo apt-get install -y python3.4 python3.4-dev
  fi
}

build_objectivec_ios() {
  # Reused the build script that takes care of configuring and ensuring things
  # are up to date.  The OS X test runs the objc conformance test, so skip it
  # here.
  # Note: travis has xctool installed, and we've looked at using it in the past
  # but it has ended up proving unreliable (bugs), an they are removing build
  # support in favor of xcbuild (or just xcodebuild).
  objectivec/DevTools/full_mac_build.sh \
      --core-only --skip-xcode-osx --skip-objc-conformance "$@"
}

build_objectivec_ios_debug() {
  build_objectivec_ios --skip-xcode-release
}

build_objectivec_ios_release() {
  build_objectivec_ios --skip-xcode-debug
}

build_objectivec_osx() {
  # Reused the build script that takes care of configuring and ensuring things
  # are up to date.
  objectivec/DevTools/full_mac_build.sh \
      --core-only --skip-xcode-ios
}

build_objectivec_cocoapods_integration() {
  # First, load the RVM environment in bash, needed to update ruby.
  source ~/.rvm/scripts/rvm
  # Update rvm to the latest version. This is needed to solve
  # https://github.com/google/protobuf/issues/1786 and may not be needed in the
  # future when Travis updates the default version of rvm.
  rvm get head
  # Update ruby to 2.2.3 as the default one crashes with segmentation faults
  # when using pod.
  rvm use 2.2.3 --install --binary --fuzzy
  # Update pod to the latest version.
  gem install cocoapods --no-ri --no-rdoc
  objectivec/Tests/CocoaPods/run_tests.sh
}

build_python() {
  internal_build_cpp
  internal_install_python_deps
  cd python
  # Only test Python 2.6/3.x on Linux
  if [ $(uname -s) == "Linux" ]; then
    envlist=py\{26,27,33,34\}-python
  else
    envlist=py27-python
  fi
  tox -e $envlist
  cd ..
}

build_python_cpp() {
  internal_build_cpp
  internal_install_python_deps
  export LD_LIBRARY_PATH=../src/.libs # for Linux
  export DYLD_LIBRARY_PATH=../src/.libs # for OS X
  cd python
  # Only test Python 2.6/3.x on Linux
  if [ $(uname -s) == "Linux" ]; then
    # py26 is currently disabled due to json_format
    envlist=py\{27,33,34\}-cpp
  else
    envlist=py27-cpp
  fi
  tox -e $envlist
  cd ..
}

build_ruby19() {
  internal_build_cpp  # For conformance tests.
  cd ruby && bash travis-test.sh ruby-1.9 && cd ..
}
build_ruby20() {
  internal_build_cpp  # For conformance tests.
  cd ruby && bash travis-test.sh ruby-2.0 && cd ..
}
build_ruby21() {
  internal_build_cpp  # For conformance tests.
  cd ruby && bash travis-test.sh ruby-2.1 && cd ..
}
build_ruby22() {
  internal_build_cpp  # For conformance tests.
  cd ruby && bash travis-test.sh ruby-2.2 && cd ..
}
build_jruby() {
  internal_build_cpp  # For conformance tests.
  cd ruby && bash travis-test.sh jruby && cd ..
}

build_javascript() {
  internal_build_cpp
  cd js && npm install && npm test && cd ..
}

# Note: travis currently does not support testing more than one language so the
# .travis.yml cheats and claims to only be cpp.  If they add multiple language
# support, this should probably get updated to install steps and/or
# rvm/gemfile/jdk/etc. entries rather than manually doing the work.

# .travis.yml uses matrix.exclude to block the cases where app-get can't be
# use to install things.

# -------- main --------

if [ "$#" -ne 1 ]; then
  echo "
Usage: $0 { cpp |
            csharp |
            java_jdk6 |
            java_jdk7 |
            java_oracle7 |
            javanano_jdk6 |
            javanano_jdk7 |
            javanano_oracle7 |
            objectivec_ios |
            objectivec_ios_debug |
            objectivec_ios_release |
            objectivec_osx |
            objectivec_cocoapods_integration |
            python |
            python_cpp |
            ruby19 |
            ruby20 |
            ruby21 |
            ruby22 |
            jruby }
"
  exit 1
fi

set -e  # exit immediately on error
set -x  # display all commands
eval "build_$1"
