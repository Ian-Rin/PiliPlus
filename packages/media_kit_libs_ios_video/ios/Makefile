all: Frameworks/*.xcframework Frameworks/.symlinks

# Where the archive comes from, its release and its sha256. This package
# is media_kit_libs_ios_video of the media-kit fork the app uses, copied
# here to name these three.
#
# The fork names gungun974/melodink-libmpv-darwin-build v0.39.0 (mpv
# 0.39.0, ffmpeg 7.0.2; sha256
# d7a996b2afad622e9bafb53f1f988235938af33fe162840c9c74a1894bde4bfc), a
# build repository left alone since 2024. This is the same build (the
# branch mpv-0.39 of Ian-Rin/libmpv-darwin-build: the same versions,
# options and files) with one patch of ffmpeg's more,
# patches/ffmpeg-videotoolbox-async.patch: a frame is given to
# VideoToolbox without waiting for the picture of the one before, which
# held 4K decoding to some 125 frames a second.
#
# media-kit's own build (v0.7.3: mpv 0.36.0, ffmpeg 6.0) was tried and
# stuttered on an iPhone 17 Pro: every few seconds in plain playback,
# sound and picture, and at each change of speed.
MPV_XCFRAMEWORKS_REPO=Ian-Rin/libmpv-darwin-build
MPV_XCFRAMEWORKS_VERSION=v0.39.0-async1
MPV_XCFRAMEWORKS_SHA256SUM=0d328cbb83c3a8783c5ca60bddd2b066c8310887c5e46b7142c19ce1a47ba426

.cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz:
	mkdir -p .cache/xcframeworks
	rm -f .cache/xcframeworks/*.tmp .cache/xcframeworks/*-ios-universal.tar.gz
	curl -L \
		https://github.com/${MPV_XCFRAMEWORKS_REPO}/releases/download/${MPV_XCFRAMEWORKS_VERSION}/libmpv-xcframeworks_${MPV_XCFRAMEWORKS_VERSION}_ios-universal-video-default.tar.gz \
		-o .cache/xcframeworks/libmpv.tar.gz.tmp
	shasum -a 256 -c <<< '${MPV_XCFRAMEWORKS_SHA256SUM}  .cache/xcframeworks/libmpv.tar.gz.tmp'
	mv .cache/xcframeworks/libmpv.tar.gz.tmp .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz
	touch .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz

.cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz: .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz
	rm -f .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz
	ln -s libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-ios-universal.tar.gz .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz

Frameworks/*.xcframework: .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz
	mkdir -p Frameworks
	rm -rf Frameworks/*.xcframework
	tar -xvf .cache/xcframeworks/libmpv-xcframeworks-ios-universal.tar.gz --strip-components 1 -C Frameworks
	touch Frameworks/*.xcframework

Frameworks/.symlinks: Frameworks/*.xcframework
	rm -rf Frameworks/.symlinks
	mkdir -p Frameworks/.symlinks/mpv
	sed -i '' 's/\r$$//g' create_framework_symlinks.sh # remove CRLF line terminator added by Flutter packaging (https://github.com/media-kit/media-kit/issues/338)
	sh create_framework_symlinks.sh Frameworks/Mpv.xcframework Frameworks/.symlinks/mpv

.PHONY: clean
clean:
	rm -rf .cache
	rm -f ./Headers/mpv/*.h
	rm -rf ./Frameworks/*.xcframework
