/*****************************************************************************\
     Snes9x - Portable Super Nintendo Entertainment System (TM) emulator.
                This file is licensed under the Snes9x License.
   For further information, consult the LICENSE file in the root directory.
\*****************************************************************************/

/***********************************************************************************
  SNES9X for Mac OS (c) Copyright John Stiles

  Snes9x for Mac OS X

  (c) Copyright 2001 - 2011  zones
  (c) Copyright 2002 - 2005  107
  (c) Copyright 2002         PB1400c
  (c) Copyright 2004         Alexander and Sander
  (c) Copyright 2004 - 2005  Steven Seeger
  (c) Copyright 2005         Ryan Vogt
 ***********************************************************************************/


#include "snes9x.h"
#include "memmap.h"
#include "apu.h"

#include <QuickTime/QuickTime.h>

#include "mac-prefix.h"
#include "mac-gworld.h"
#include "mac-os.h"
#include "mac-screenshot.h"
#include "mac-quicktime.h"

#define	kMovDoubleSize		(1 << 0)
#define	kMovExtendedHeight	(1 << 1)

static void CheckError (OSStatus, int);
static void MacQTOpenVideoComponent (ComponentInstance *);
static void MacQTCloseVideoComponent (ComponentInstance);
static OSStatus WriteFrameCallBack (void *, ICMCompressionSessionRef, OSStatus, ICMEncodedFrameRef, void *);

typedef struct
{
	Movie							movie;
	Track							vTrack, sTrack;
	Media							vMedia, sMedia;
	ComponentInstance				vci;
	SoundDescriptionHandle			soundDesc;
	DataHandler						dataHandler;
	Handle							soundBuffer;
	Handle							dataRef;
	OSType							dataRefType;
	CVPixelBufferPoolRef			pool;
	ICMCompressionSessionRef		session;
	ICMCompressionSessionOptionsRef	option;
	CGImageRef						srcImage;
	TimeValue64						timeStamp;
	long							keyFrame, keyFrameCount;
	long							frameSkip, frameSkipCount;
	int								width, height;
	int								soundBufferSize;
	int								samplesPerSec;
}	MacQTState;

static MacQTState	sqt;


static void CheckError (OSStatus err, int n)
{
	if (err != noErr)
	{
		char	mes[32];

		sprintf(mes, "quicktime %02d", n);
		QuitWithFatalError(err, mes);
	}
}

static void MacQTOpenVideoComponent (ComponentInstance *rci)
{
	OSStatus			err;
	ComponentInstance	ci;
	CFDataRef			data;

	ci = OpenDefaultComponent(StandardCompressionType, StandardCompressionSubType);

	data = (CFDataRef) CFPreferencesCopyAppValue(CFSTR("QTVideoSetting"), kCFPreferencesCurrentApplication);
	if (data)
	{
		CFIndex	len;
		Handle	hdl;

		len = CFDataGetLength(data);
		hdl = NewHandleClear((Size) len);
		if (MemError() == noErr)
		{
			HLock(hdl);
			CFDataGetBytes(data, CFRangeMake(0, len), (unsigned char *) *hdl);
			err = SCSetInfo(ci, scSettingsStateType, &hdl);

			DisposeHandle(hdl);
		}

		CFRelease(data);
	}
	else
	{
		SCSpatialSettings	ss;
		SCTemporalSettings	ts;

		ss.codecType       = kAnimationCodecType;
		ss.codec           = 0;
		ss.depth           = 16;
		ss.spatialQuality  = codecMaxQuality;
		err = SCSetInfo(ci, scSpatialSettingsType, &ss);

		ts.frameRate       = FixRatio(Memory.ROMFramesPerSecond, 1);
		ts.keyFrameRate    = Memory.ROMFramesPerSecond;
		ts.temporalQuality = codecMaxQuality;
		err = SCSetInfo(ci, scTemporalSettingsType, &ts);
	}

	*rci = ci;
}

static void MacQTCloseVideoComponent (ComponentInstance ci)
{
	OSStatus	err;

	err = CloseComponent(ci);
}

void MacQTVideoConfig (void)
{
	OSStatus			err;
	ComponentInstance	ci;

	MacQTOpenVideoComponent(&ci);

	long	flag;
	flag = scListEveryCodec | scAllowZeroKeyFrameRate | scDisableFrameRateItem | scAllowEncodingWithCompressionSession;
	err = SCSetInfo(ci, scPreferenceFlagsType, &flag);

	SCWindowSettings	ws;
	ws.size          = sizeof(SCWindowSettings);
	ws.windowRefKind = scWindowRefKindCarbon;
	ws.parentWindow  = NULL;
	err = SCSetInfo(ci, scWindowOptionsType, &ws);

	err = SCRequestSequenceSettings(ci);
	if (err == noErr)
	{
		CFDataRef	data;
		Handle		hdl;

		err = SCGetInfo(ci, scSettingsStateType, &hdl);
		if (err == noErr)
		{
			HLock(hdl);
			data = CFDataCreate(kCFAllocatorDefault, (unsigned char *) *hdl, GetHandleSize(hdl));
			if (data)
			{
				CFPreferencesSetAppValue(CFSTR("QTVideoSetting"), data, kCFPreferencesCurrentApplication);
				CFRelease(data);
			}

			DisposeHandle(hdl);
		}
	}

	MacQTCloseVideoComponent(ci);
}

void MacQTStartRecording (char *path)
{
	OSStatus	err;
	CFStringRef str;
	CFURLRef	url;

	memset(&sqt, 0, sizeof(sqt));

	// storage

	str = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);
	url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, str, kCFURLPOSIXPathStyle, false);
	err = QTNewDataReferenceFromCFURL(url, 0, &(sqt.dataRef), &(sqt.dataRefType));
	CheckError(err, 21);
	CFRelease(url);
	CFRelease(str);

	err = CreateMovieStorage(sqt.dataRef, sqt.dataRefType, 'TVOD', smSystemScript, createMovieFileDeleteCurFile | newMovieActive, &(sqt.dataHandler), &(sqt.movie));
	CheckError(err, 22);

	// video

	MacQTOpenVideoComponent(&(sqt.vci));

	long				flag;
	SCTemporalSettings	ts;

	flag = scAllowEncodingWithCompressionSession;
	err = SCSetInfo(sqt.vci, scPreferenceFlagsType, &flag);

	err = SCGetInfo(sqt.vci, scTemporalSettingsType, &ts);
	ts.frameRate = FixRatio(Memory.ROMFramesPerSecond, 1);
	if (ts.keyFrameRate < 1)
		ts.keyFrameRate = Memory.ROMFramesPerSecond;
	sqt.keyFrame  = sqt.keyFrameCount  = ts.keyFrameRate;
	sqt.frameSkip = sqt.frameSkipCount = (macQTMovFlag & 0xFF00) >> 8;
	err = SCSetInfo(sqt.vci, scTemporalSettingsType, &ts);

	sqt.width  = ((macQTMovFlag & kMovDoubleSize) ? 2 : 1) * SNES_WIDTH;
	sqt.height = ((macQTMovFlag & kMovDoubleSize) ? 2 : 1) * ((macQTMovFlag & kMovExtendedHeight) ? SNES_HEIGHT_EXTENDED : SNES_HEIGHT);

	sqt.srcImage = NULL;
	sqt.timeStamp = 0;

	SCSpatialSettings			ss;
	ICMEncodedFrameOutputRecord	record;
	ICMMultiPassStorageRef		nullStorage = NULL;

	err = SCCopyCompressionSessionOptions(sqt.vci, &(sqt.option));
	CheckError(err, 61);
	err = ICMCompressionSessionOptionsSetProperty(sqt.option, kQTPropertyClass_ICMCompressionSessionOptions, kICMCompressionSessionOptionsPropertyID_MultiPassStorage, sizeof(ICMMultiPassStorageRef), &nullStorage);

	record.encodedFrameOutputCallback = WriteFrameCallBack;
	record.encodedFrameOutputRefCon   = NULL;
	record.frameDataAllocator         = NULL;
	err = SCGetInfo(sqt.vci, scSpatialSettingsType, &ss);
	err = ICMCompressionSessionCreate(kCFAllocatorDefault, sqt.width, sqt.height, ss.codecType, Memory.ROMFramesPerSecond, sqt.option, NULL, &record, &(sqt.session));
	CheckError(err, 62);

	CFMutableDictionaryRef	dic;
	CFNumberRef				val;
	OSType					pix = k16BE555PixelFormat;
	int						row = sqt.width * 2;

	dic = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

	val = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pix);
	CFDictionaryAddValue(dic, kCVPixelBufferPixelFormatTypeKey, val);
	CFRelease(val);

	val = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(sqt.width));
	CFDictionaryAddValue(dic, kCVPixelBufferWidthKey, val);
	CFRelease(val);

	val = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &(sqt.height));
	CFDictionaryAddValue(dic, kCVPixelBufferHeightKey, val);
	CFRelease(val);

	val = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &row);
	CFDictionaryAddValue(dic, kCVPixelBufferBytesPerRowAlignmentKey, val);
	CFRelease(val);

	CFDictionaryAddValue(dic, kCVPixelBufferCGImageCompatibilityKey, kCFBooleanTrue);
	CFDictionaryAddValue(dic, kCVPixelBufferCGBitmapContextCompatibilityKey, kCFBooleanTrue);

	err = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, dic, &(sqt.pool));
	CheckError(err, 63);

	CFRelease(dic);

	sqt.vTrack = NewMovieTrack(sqt.movie, FixRatio(sqt.width, 1), FixRatio(sqt.height, 1), kNoVolume);
	CheckError(GetMoviesError(), 23);

	sqt.vMedia = NewTrackMedia(sqt.vTrack, VideoMediaType, Memory.ROMFramesPerSecond, NULL, 0);
	CheckError(GetMoviesError(), 24);

	err = BeginMediaEdits(sqt.vMedia);
	CheckError(err, 25);

	// sound

	sqt.soundDesc = (SoundDescriptionHandle) NewHandleClear(sizeof(SoundDescription));
	CheckError(MemError(), 26);

	(**sqt.soundDesc).descSize    = sizeof(SoundDescription);
#ifdef __BIG_ENDIAN__
	(**sqt.soundDesc).dataFormat  = Settings.SixteenBitSound ? k16BitBigEndianFormat    : k8BitOffsetBinaryFormat;
#else
	(**sqt.soundDesc).dataFormat  = Settings.SixteenBitSound ? k16BitLittleEndianFormat : k8BitOffsetBinaryFormat;
#endif
	(**sqt.soundDesc).numChannels = Settings.Stereo ? 2 : 1;
	(**sqt.soundDesc).sampleSize  = Settings.SixteenBitSound ? 16 : 8;
	(**sqt.soundDesc).sampleRate  = (UnsignedFixed) FixRatio(Settings.SoundPlaybackRate, 1);

	sqt.samplesPerSec = Settings.SoundPlaybackRate / Memory.ROMFramesPerSecond;

	sqt.soundBufferSize = sqt.samplesPerSec;
	if (Settings.SixteenBitSound)
		sqt.soundBufferSize <<= 1;
	if (Settings.Stereo)
		sqt.soundBufferSize <<= 1;

	sqt.soundBuffer = NewHandleClear(sqt.soundBufferSize);
	CheckError(MemError(), 27);
	HLock(sqt.soundBuffer);

	sqt.sTrack = NewMovieTrack(sqt.movie, 0, 0, kFullVolume);
	CheckError(GetMoviesError(), 28);

	sqt.sMedia = NewTrackMedia(sqt.sTrack, SoundMediaType, Settings.SoundPlaybackRate, NULL, 0);
	CheckError(GetMoviesError(), 29);

	err = BeginMediaEdits(sqt.sMedia);
	CheckError(err, 30);
}

void MacQTRecordFrame (int width, int height)
{
	OSStatus	err;

	// video

	if (sqt.frameSkipCount == sqt.frameSkip)
	{
		CVPixelBufferRef	buf;

		err = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, sqt.pool, &buf);
		if (err == noErr)
		{
			CGColorSpaceRef		color;
			CGContextRef		ctx;
			uint16				*p;

			err = CVPixelBufferLockBaseAddress(buf, 0);
			p = (uint16 *) CVPixelBufferGetBaseAddress(buf);

			color = CGColorSpaceCreateDeviceRGB();
			ctx = CGBitmapContextCreate((void *) p, sqt.width, sqt.height, 5, sqt.width * 2, color, kCGImageAlphaNoneSkipFirst | ((systemVersion >= 0x1040) ? kCGBitmapByteOrder16Host : 0));
			CGContextSetShouldAntialias(ctx, false);

			if (sqt.srcImage)
				CGImageRelease(sqt.srcImage);
			sqt.srcImage = CreateGameScreenCGImage();

			CGRect	dst = CGRectMake(0.0f, 0.0f, (float) sqt.width, (float) sqt.height);

			if ((!(height % SNES_HEIGHT_EXTENDED)) && (!(macQTMovFlag & kMovExtendedHeight)))
			{
				CGRect	src;

				src.size.width  = (float) width;
				src.size.height = (float) ((height > 256) ? (SNES_HEIGHT << 1) : SNES_HEIGHT);
				src.origin.x    = (float) 0;
				src.origin.y    = (float) height - src.size.height;
				DrawSubCGImage(ctx, sqt.srcImage, src, dst);
			}
			else
			if ((sqt.height << 1) % height)
			{
				CGContextSetRGBFillColor(ctx, 0.0f, 0.0f, 0.0f, 1.0f);
				CGContextFillRect(ctx, dst);

				float	dh  = (float) ((sqt.height > 256) ? (SNES_HEIGHT << 1) : SNES_HEIGHT);
				float	ofs = (float) ((int) ((drawoverscan ? 1.0 : 0.5) * ((float) sqt.height - dh) + 0.5));
				dst = CGRectMake(0.0f, ofs, (float) sqt.width, dh);
				CGContextDrawImage(ctx, dst, sqt.srcImage);
			}
			else
				CGContextDrawImage(ctx, dst, sqt.srcImage);

			CGContextRelease(ctx);
			CGColorSpaceRelease(color);

		#ifndef __BIG_ENDIAN__
			for (int i = 0; i < sqt.width * sqt.height; i++)
				SWAP_WORD(p[i]);
		#endif

			err = CVPixelBufferUnlockBaseAddress(buf, 0);

			err = ICMCompressionSessionEncodeFrame(sqt.session, buf, sqt.timeStamp, 0, kICMValidTime_DisplayTimeStampIsValid, NULL, NULL, NULL);

			CVPixelBufferRelease(buf);
		}

		sqt.keyFrameCount--;
		if (sqt.keyFrameCount <= 0)
			sqt.keyFrameCount = sqt.keyFrame;
	}

	sqt.frameSkipCount--;
	if (sqt.frameSkipCount < 0)
		sqt.frameSkipCount = sqt.frameSkip;

	sqt.timeStamp++;

	// sound

	int	sample_count = sqt.soundBufferSize;
	if (Settings.SixteenBitSound)
		sample_count >>= 1;

	S9xMixSamples((uint8 *) *(sqt.soundBuffer), sample_count);

	err = AddMediaSample(sqt.sMedia, sqt.soundBuffer, 0, sqt.soundBufferSize, 1, (SampleDescriptionHandle) sqt.soundDesc, sqt.samplesPerSec, mediaSampleNotSync, NULL);
}

static OSStatus WriteFrameCallBack (void *refCon, ICMCompressionSessionRef session, OSStatus r, ICMEncodedFrameRef frame, void *reserved)
{
	OSStatus	err;

	err = AddMediaSampleFromEncodedFrame(sqt.vMedia, frame, NULL);
	return (err);
}

void MacQTStopRecording (void)
{
	OSStatus   err;

	// video

	err = ICMCompressionSessionCompleteFrames(sqt.session, true, 0, sqt.timeStamp);
	err = ExtendMediaDecodeDurationToDisplayEndTime(sqt.vMedia, NULL);

	err = EndMediaEdits(sqt.vMedia);
	CheckError(err, 52);

	err = InsertMediaIntoTrack(sqt.vTrack, 0, 0, (TimeValue) GetMediaDisplayDuration(sqt.vMedia), fixed1);
	CheckError(err, 58);

	CGImageRelease(sqt.srcImage);
	CVPixelBufferPoolRelease(sqt.pool);
	ICMCompressionSessionRelease(sqt.session);
	ICMCompressionSessionOptionsRelease(sqt.option);

	// sound

	err = EndMediaEdits(sqt.sMedia);
	CheckError(err, 54);

	err = InsertMediaIntoTrack(sqt.sTrack, 0, 0, GetMediaDuration(sqt.sMedia), fixed1);
	CheckError(err, 55);

	DisposeHandle(sqt.soundBuffer);
	DisposeHandle((Handle) sqt.soundDesc);

	// storage

	err = AddMovieToStorage(sqt.movie, sqt.dataHandler);
	CheckError(err, 56);

	MacQTCloseVideoComponent(sqt.vci);

	err = CloseMovieStorage(sqt.dataHandler);
	CheckError(err, 57);

	DisposeHandle(sqt.dataRef);
	DisposeMovie(sqt.movie);
}
