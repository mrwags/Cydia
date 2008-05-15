/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008  Jay Freeman (saurik)
*/

/*
 *        Redistribution and use in source and binary
 * forms, with or without modification, are permitted
 * provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer in the documentation
 *    and/or other materials provided with the
 *    distribution.
 * 3. The name of the author may not be used to endorse
 *    or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

/* #include Directives {{{ */
#include <objc/objc.h>
#include <objc/runtime.h>

#include <CoreGraphics/CoreGraphics.h>
#include <GraphicsServices/GraphicsServices.h>
#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <WebCore/DOMHTML.h>

#import "BrowserView.h"
#import "ResetView.h"
#import "UICaboodle.h"

#include <WebKit/WebFrame.h>
#include <WebKit/WebView.h>

#include <sstream>
#include <string>

#include <ext/stdio_filebuf.h>

#include <apt-pkg/acquire.h>
#include <apt-pkg/acquire-item.h>
#include <apt-pkg/algorithms.h>
#include <apt-pkg/cachefile.h>
#include <apt-pkg/clean.h>
#include <apt-pkg/configuration.h>
#include <apt-pkg/debmetaindex.h>
#include <apt-pkg/error.h>
#include <apt-pkg/init.h>
#include <apt-pkg/pkgrecords.h>
#include <apt-pkg/sourcelist.h>
#include <apt-pkg/sptr.h>

#include <sys/sysctl.h>
#include <notify.h>

extern "C" {
#include <mach-o/nlist.h>
}

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <errno.h>
#include <pcre.h>
/* }}} */

/* iPhoneOS 2.0 Compatibility {{{ */
#ifdef __OBJC2__
@interface UICGColor : NSObject {
}

- (id) initWithCGColor:(CGColorRef)color;
@end

@interface UIFont {
}

- (UIFont *) fontWithSize:(CGFloat)size;
@end

@interface NSObject (iPhoneOS)
- (CGColorRef) cgColor;
- (CGColorRef) CGColor;
- (void) set;
@end

@implementation NSObject (iPhoneOS)

- (CGColorRef) cgColor {
    return [self CGColor];
}

- (CGColorRef) CGColor {
    return (CGColorRef) self;
}

- (void) set {
    [[[[objc_getClass("UICGColor") alloc] initWithCGColor:[self CGColor]] autorelease] set];
}

@end

@interface UITextView (iPhoneOS)
- (void) setTextSize:(float)size;
@end

@implementation UITextView (iPhoneOS)

- (void) setTextSize:(float)size {
    [self setFont:[[self font] fontWithSize:size]];
}

@end
#endif
/* }}} */

@interface NSString (UIKit)
- (NSString *) stringByAddingPercentEscapes;
- (NSString *) stringByReplacingCharacter:(unsigned short)arg0 withCharacter:(unsigned short)arg1;
@end

@interface NSString (Cydia)
+ (NSString *) stringWithUTF8Bytes:(const char *)bytes length:(int)length;
- (NSComparisonResult) compareByPath:(NSString *)other;
@end

@implementation NSString (Cydia)

+ (NSString *) stringWithUTF8Bytes:(const char *)bytes length:(int)length {
    char data[length + 1];
    memcpy(data, bytes, length);
    data[length] = '\0';
    return [NSString stringWithUTF8String:data];
}

- (NSComparisonResult) compareByPath:(NSString *)other {
    NSString *prefix = [self commonPrefixWithString:other options:0];
    size_t length = [prefix length];

    NSRange lrange = NSMakeRange(length, [self length] - length);
    NSRange rrange = NSMakeRange(length, [other length] - length);

    lrange = [self rangeOfString:@"/" options:0 range:lrange];
    rrange = [other rangeOfString:@"/" options:0 range:rrange];

    NSComparisonResult value;

    if (lrange.location == NSNotFound && rrange.location == NSNotFound)
        value = NSOrderedSame;
    else if (lrange.location == NSNotFound)
        value = NSOrderedAscending;
    else if (rrange.location == NSNotFound)
        value = NSOrderedDescending;
    else
        value = NSOrderedSame;

    NSString *lpath = lrange.location == NSNotFound ? [self substringFromIndex:length] :
        [self substringWithRange:NSMakeRange(length, lrange.location - length)];
    NSString *rpath = rrange.location == NSNotFound ? [other substringFromIndex:length] :
        [other substringWithRange:NSMakeRange(length, rrange.location - length)];

    NSComparisonResult result = [lpath compare:rpath];
    return result == NSOrderedSame ? value : result;
}

@end

/* Perl-Compatible RegEx {{{ */
class Pcre {
  private:
    pcre *code_;
    pcre_extra *study_;
    int capture_;
    int *matches_;
    const char *data_;

  public:
    Pcre(const char *regex) :
        study_(NULL)
    {
        const char *error;
        int offset;
        code_ = pcre_compile(regex, 0, &error, &offset, NULL);

        if (code_ == NULL) {
            fprintf(stderr, "%d:%s\n", offset, error);
            _assert(false);
        }

        pcre_fullinfo(code_, study_, PCRE_INFO_CAPTURECOUNT, &capture_);
        matches_ = new int[(capture_ + 1) * 3];
    }

    ~Pcre() {
        pcre_free(code_);
        delete matches_;
    }

    NSString *operator [](size_t match) {
        return [NSString stringWithUTF8Bytes:(data_ + matches_[match * 2]) length:(matches_[match * 2 + 1] - matches_[match * 2])];
    }

    bool operator ()(NSString *data) {
        // XXX: length is for characters, not for bytes
        return operator ()([data UTF8String], [data length]);
    }

    bool operator ()(const char *data, size_t size) {
        data_ = data;
        return pcre_exec(code_, study_, data, size, 0, 0, matches_, (capture_ + 1) * 3) >= 0;
    }
};
/* }}} */
/* Mime Addresses {{{ */
Pcre email_r("^\"?(.*)\"? <([^>]*)>$");

@interface Address : NSObject {
    NSString *name_;
    NSString *email_;
}

- (NSString *) name;
- (NSString *) email;

+ (Address *) addressWithString:(NSString *)string;
- (Address *) initWithString:(NSString *)string;
@end

@implementation Address

- (void) dealloc {
    [name_ release];
    if (email_ != nil)
        [email_ release];
    [super dealloc];
}

- (NSString *) name {
    return name_;
}

- (NSString *) email {
    return email_;
}

+ (Address *) addressWithString:(NSString *)string {
    return [[[Address alloc] initWithString:string] autorelease];
}

- (Address *) initWithString:(NSString *)string {
    if ((self = [super init]) != nil) {
        const char *data = [string UTF8String];
        size_t size = [string length];

        if (email_r(data, size)) {
            name_ = [email_r[1] retain];
            email_ = [email_r[2] retain];
        } else {
            name_ = [[NSString alloc]
                initWithBytes:data
                length:size
                encoding:kCFStringEncodingUTF8
            ];

            email_ = nil;
        }
    } return self;
}

@end
/* }}} */
/* CoreGraphics Primitives {{{ */
class CGColor {
  private:
    CGColorRef color_;

  public:
    CGColor() :
        color_(NULL)
    {
    }

    CGColor(CGColorSpaceRef space, float red, float green, float blue, float alpha) :
        color_(NULL)
    {
        Set(space, red, green, blue, alpha);
    }

    void Clear() {
        if (color_ != NULL)
            CGColorRelease(color_);
    }

    ~CGColor() {
        Clear();
    }

    void Set(CGColorSpaceRef space, float red, float green, float blue, float alpha) {
        Clear();
        float color[] = {red, green, blue, alpha};
        color_ = CGColorCreate(space, color);
    }

    operator CGColorRef() {
        return color_;
    }
};

class GSFont {
  private:
    GSFontRef font_;

  public:
    ~GSFont() {
        CFRelease(font_);
    }
};
/* }}} */
/* Right Alignment {{{ */
@interface UIRightTextLabel : UITextLabel {
    float       _savedRightEdgeX;
    BOOL        _sizedtofit_flag;
}

- (void) setFrame:(CGRect)frame;
- (void) setText:(NSString *)text;
- (void) realignText;
@end

@implementation UIRightTextLabel

- (void) setFrame:(CGRect)frame {
    [super setFrame:frame];
    if (_sizedtofit_flag == NO) {
        _savedRightEdgeX = frame.origin.x;
        [self realignText];
    }
}

- (void) setText:(NSString *)text {
    [super setText:text];
    [self realignText];
}

- (void) realignText {
    CGRect oldFrame = [self frame];

    _sizedtofit_flag = YES;
    [self sizeToFit]; // shrink down size so I can right align it

    CGRect newFrame = [self frame];

    oldFrame.origin.x = _savedRightEdgeX - newFrame.size.width;
    oldFrame.size.width = newFrame.size.width;
    [super setFrame:oldFrame];
    _sizedtofit_flag = NO;
}

@end
/* }}} */

/* Random Global Variables {{{ */
static const int PulseInterval_ = 50000;
static const int ButtonBarHeight_ = 48;
static const float KeyboardTime_ = 0.4f;

#ifndef Cydia_
#define Cydia_ ""
#endif

static CGColor Blueish_;
static CGColor Black_;
static CGColor Clear_;
static CGColor Red_;
static CGColor White_;

static NSString *Home_;
static BOOL Sounds_Keyboard_;

static BOOL Advanced_;
static BOOL Loaded_;
static BOOL Ignored_;

const char *Firmware_ = NULL;
const char *Machine_ = NULL;
const char *SerialNumber_ = NULL;

unsigned Major_;
unsigned Minor_;
unsigned BugFix_;

CGColorSpaceRef space_;

#define FW_LEAST(major, minor, bugfix) \
    (major < Major_ || major == Major_ && \
        (minor < Minor_ || minor == Minor_ && \
            bugfix <= BugFix_))

bool bootstrap_;
bool reload_;

static NSMutableDictionary *Metadata_;
static NSMutableDictionary *Packages_;
static bool Changed_;
static NSDate *now_;

NSString *GetLastUpdate() {
    NSDate *update = [Metadata_ objectForKey:@"LastUpdate"];

    if (update == nil)
        return @"Never or Unknown";

    CFLocaleRef locale = CFLocaleCopyCurrent();
    CFDateFormatterRef formatter = CFDateFormatterCreate(NULL, locale, kCFDateFormatterMediumStyle, kCFDateFormatterMediumStyle);
    CFStringRef formatted = CFDateFormatterCreateStringWithDate(NULL, formatter, (CFDateRef) update);

    CFRelease(formatter);
    CFRelease(locale);

    return [(NSString *) formatted autorelease];
}
/* }}} */
/* Display Helpers {{{ */
inline float Interpolate(float begin, float end, float fraction) {
    return (end - begin) * fraction + begin;
}

NSString *SizeString(double size) {
    unsigned power = 0;
    while (size > 1024) {
        size /= 1024;
        ++power;
    }

    static const char *powers_[] = {"B", "kB", "MB", "GB"};

    return [NSString stringWithFormat:@"%.1f%s", size, powers_[power]];
}

static const float TextViewOffset_ = 22;

UITextView *GetTextView(NSString *value, float left, bool html) {
    UITextView *text([[[UITextView alloc] initWithFrame:CGRectMake(left, 3, 310 - left, 1000)] autorelease]);
    [text setEditable:NO];
    [text setTextSize:16];
    /*if (html)
        [text setHTML:value];
    else*/
        [text setText:value];
    [text setEnabled:NO];

    [text setBackgroundColor:Clear_];

    CGRect frame = [text frame];
    [text setFrame:frame];
    CGRect rect = [text visibleTextRect];
    frame.size.height = rect.size.height;
    [text setFrame:frame];

    return text;
}

NSString *Simplify(NSString *title) {
    const char *data = [title UTF8String];
    size_t size = [title length];

    Pcre title_r("^(.*?)( \\(.*\\))?$");
    if (title_r(data, size))
        return title_r[1];
    else
        return title;
}
/* }}} */

/* Delegate Prototypes {{{ */
@class Package;
@class Source;

@protocol ProgressDelegate
- (void) setProgressError:(NSString *)error;
- (void) setProgressTitle:(NSString *)title;
- (void) setProgressPercent:(float)percent;
- (void) addProgressOutput:(NSString *)output;
@end

@protocol ConfigurationDelegate
- (void) repairWithSelector:(SEL)selector;
- (void) setConfigurationData:(NSString *)data;
@end

@protocol CydiaDelegate
- (void) installPackage:(Package *)package;
- (void) removePackage:(Package *)package;
- (void) slideUp:(UIAlertSheet *)alert;
- (void) distUpgrade;
@end
/* }}} */

/* Status Delegation {{{ */
class Status :
    public pkgAcquireStatus
{
  private:
    _transient id<ProgressDelegate> delegate_;

  public:
    Status() :
        delegate_(nil)
    {
    }

    void setDelegate(id delegate) {
        delegate_ = delegate;
    }

    virtual bool MediaChange(std::string media, std::string drive) {
        return false;
    }

    virtual void IMSHit(pkgAcquire::ItemDesc &item) {
    }

    virtual void Fetch(pkgAcquire::ItemDesc &item) {
        [delegate_ setProgressTitle:[NSString stringWithUTF8String:("Downloading " + item.ShortDesc).c_str()]];
    }

    virtual void Done(pkgAcquire::ItemDesc &item) {
    }

    virtual void Fail(pkgAcquire::ItemDesc &item) {
        if (
            item.Owner->Status == pkgAcquire::Item::StatIdle ||
            item.Owner->Status == pkgAcquire::Item::StatDone
        )
            return;

        [delegate_ setProgressError:[NSString stringWithUTF8String:item.Owner->ErrorText.c_str()]];
    }

    virtual bool Pulse(pkgAcquire *Owner) {
        bool value = pkgAcquireStatus::Pulse(Owner);

        float percent(
            double(CurrentBytes + CurrentItems) /
            double(TotalBytes + TotalItems)
        );

        [delegate_ setProgressPercent:percent];
        return value;
    }

    virtual void Start() {
    }

    virtual void Stop() {
    }
};
/* }}} */
/* Progress Delegation {{{ */
class Progress :
    public OpProgress
{
  private:
    _transient id<ProgressDelegate> delegate_;

  protected:
    virtual void Update() {
        [delegate_ setProgressTitle:[NSString stringWithUTF8String:Op.c_str()]];
        [delegate_ setProgressPercent:(Percent / 100)];
    }

  public:
    Progress() :
        delegate_(nil)
    {
    }

    void setDelegate(id delegate) {
        delegate_ = delegate;
    }

    virtual void Done() {
        [delegate_ setProgressPercent:1];
    }
};
/* }}} */

/* Database Interface {{{ */
@interface Database : NSObject {
    pkgCacheFile cache_;
    pkgDepCache::Policy *policy_;
    pkgRecords *records_;
    pkgProblemResolver *resolver_;
    pkgAcquire *fetcher_;
    FileFd *lock_;
    SPtr<pkgPackageManager> manager_;
    pkgSourceList *list_;

    NSMutableDictionary *sources_;
    NSMutableArray *packages_;

    _transient id<ConfigurationDelegate, ProgressDelegate> delegate_;
    Status status_;
    Progress progress_;

    int cydiafd_;
    int statusfd_;
    FILE *input_;
}

- (void) _readCydia:(NSNumber *)fd;
- (void) _readStatus:(NSNumber *)fd;
- (void) _readOutput:(NSNumber *)fd;

- (FILE *) input;

- (Package *) packageWithName:(NSString *)name;

- (Database *) init;
- (pkgCacheFile &) cache;
- (pkgDepCache::Policy *) policy;
- (pkgRecords *) records;
- (pkgProblemResolver *) resolver;
- (pkgAcquire &) fetcher;
- (NSArray *) packages;
- (void) reloadData;

- (void) configure;
- (void) prepare;
- (void) perform;
- (void) upgrade;
- (void) update;

- (void) updateWithStatus:(Status &)status;

- (void) setDelegate:(id)delegate;
- (Source *) getSource:(const pkgCache::PkgFileIterator &)file;
@end
/* }}} */

/* Source Class {{{ */
@interface Source : NSObject {
    NSString *description_;
    NSString *label_;
    NSString *origin_;

    NSString *uri_;
    NSString *distribution_;
    NSString *type_;
    NSString *version_;

    NSString *defaultIcon_;

    BOOL trusted_;
}

- (Source *) initWithMetaIndex:(metaIndex *)index;

- (BOOL) trusted;

- (NSString *) uri;
- (NSString *) distribution;
- (NSString *) type;

- (NSString *) description;
- (NSString *) label;
- (NSString *) origin;
- (NSString *) version;

- (NSString *) defaultIcon;
@end

@implementation Source

- (void) dealloc {
    [uri_ release];
    [distribution_ release];
    [type_ release];

    if (description_ != nil)
        [description_ release];
    if (label_ != nil)
        [label_ release];
    if (origin_ != nil)
        [origin_ release];
    if (version_ != nil)
        [version_ release];
    if (defaultIcon_ != nil)
        [defaultIcon_ release];

    [super dealloc];
}

- (Source *) initWithMetaIndex:(metaIndex *)index {
    if ((self = [super init]) != nil) {
        trusted_ = index->IsTrusted();

        uri_ = [[NSString stringWithUTF8String:index->GetURI().c_str()] retain];
        distribution_ = [[NSString stringWithUTF8String:index->GetDist().c_str()] retain];
        type_ = [[NSString stringWithUTF8String:index->GetType()] retain];

        description_ = nil;
        label_ = nil;
        origin_ = nil;
        version_ = nil;
        defaultIcon_ = nil;

        debReleaseIndex *dindex(dynamic_cast<debReleaseIndex *>(index));
        if (dindex != NULL) {
            std::ifstream release(dindex->MetaIndexFile("Release").c_str());
            std::string line;
            while (std::getline(release, line)) {
                std::string::size_type colon(line.find(':'));
                if (colon == std::string::npos)
                    continue;

                std::string name(line.substr(0, colon));
                std::string value(line.substr(colon + 1));
                while (!value.empty() && value[0] == ' ')
                    value = value.substr(1);

                if (name == "Default-Icon")
                    defaultIcon_ = [[NSString stringWithUTF8String:value.c_str()] retain];
                else if (name == "Description")
                    description_ = [[NSString stringWithUTF8String:value.c_str()] retain];
                else if (name == "Label")
                    label_ = [[NSString stringWithUTF8String:value.c_str()] retain];
                else if (name == "Origin")
                    origin_ = [[NSString stringWithUTF8String:value.c_str()] retain];
                else if (name == "Version")
                    version_ = [[NSString stringWithUTF8String:value.c_str()] retain];
            }
        }
    } return self;
}

- (BOOL) trusted {
    return trusted_;
}

- (NSString *) uri {
    return uri_;
}

- (NSString *) distribution {
    return distribution_;
}

- (NSString *) type {
    return type_;
}

- (NSString *) description {
    return description_;
}

- (NSString *) label {
    return label_;
}

- (NSString *) origin {
    return origin_;
}

- (NSString *) version {
    return version_;
}

- (NSString *) defaultIcon {
    return defaultIcon_;
}

@end
/* }}} */
/* Relationship Class {{{ */
@interface Relationship : NSObject {
    NSString *type_;
    NSString *id_;
}

- (NSString *) type;
- (NSString *) id;
- (NSString *) name;

@end

@implementation Relationship

- (void) dealloc {
    [type_ release];
    [id_ release];
    [super dealloc];
}

- (NSString *) type {
    return type_;
}

- (NSString *) id {
    return id_;
}

- (NSString *) name {
    _assert(false);
    return nil;
}

@end
/* }}} */
/* Package Class {{{ */
NSString *Scour(const char *field, const char *begin, const char *end) {
    size_t i(0), l(strlen(field));

    for (;;) {
        const char *name = begin + i;
        const char *colon = name + l;
        const char *value = colon + 1;

        if (
            value < end &&
            *colon == ':' &&
            memcmp(name, field, l) == 0
        ) {
            while (value != end && value[0] == ' ')
                ++value;
            const char *line = std::find(value, end, '\n');
            while (line != value && line[-1] == ' ')
                --line;

            return [NSString stringWithUTF8Bytes:value length:(line - value)];
        } else {
            begin = std::find(begin, end, '\n');
            if (begin == end)
                return nil;
            ++begin;
        }
    }
}

@interface Package : NSObject {
    pkgCache::PkgIterator iterator_;
    _transient Database *database_;
    pkgCache::VerIterator version_;
    pkgCache::VerFileIterator file_;

    Source *source_;
    bool cached_;

    NSString *latest_;
    NSString *installed_;

    NSString *id_;
    NSString *name_;
    NSString *tagline_;
    NSString *icon_;
    NSString *website_;
    Address *author_;

    NSArray *relationships_;
}

- (Package *) initWithIterator:(pkgCache::PkgIterator)iterator database:(Database *)database;
+ (Package *) packageWithIterator:(pkgCache::PkgIterator)iterator database:(Database *)database;

- (pkgCache::PkgIterator) iterator;

- (NSString *) section;
- (Address *) maintainer;
- (size_t) size;
- (NSString *) description;
- (NSString *) index;

- (NSDate *) seen;

- (NSString *) latest;
- (NSString *) installed;

- (BOOL) valid;
- (BOOL) upgradable;
- (BOOL) essential;
- (BOOL) broken;

- (BOOL) half;
- (BOOL) halfConfigured;
- (BOOL) halfInstalled;
- (BOOL) hasMode;
- (NSString *) mode;

- (NSString *) id;
- (NSString *) name;
- (NSString *) tagline;
- (NSString *) icon;
- (NSString *) website;
- (Address *) author;

- (NSArray *) relationships;

- (Source *) source;

- (BOOL) matches:(NSString *)text;

- (NSComparisonResult) compareByName:(Package *)package;
- (NSComparisonResult) compareBySection:(Package *)package;
- (NSComparisonResult) compareBySectionAndName:(Package *)package;
- (NSComparisonResult) compareForChanges:(Package *)package;

- (void) install;
- (void) remove;

- (NSNumber *) isSearchedForBy:(NSString *)search;
- (NSNumber *) isInstalledInSection:(NSString *)section;
- (NSNumber *) isUninstalledInSection:(NSString *)section;

@end

@implementation Package

- (void) dealloc {
    if (source_ != nil)
        [source_ release];

    [latest_ release];
    if (installed_ != nil)
        [installed_ release];

    [id_ release];
    if (name_ != nil)
        [name_ release];
    [tagline_ release];
    if (icon_ != nil)
        [icon_ release];
    if (website_ != nil)
        [website_ release];
    if (author_ != nil)
        [author_ release];

    if (relationships_ != nil)
        [relationships_ release];

    [super dealloc];
}

- (Package *) initWithIterator:(pkgCache::PkgIterator)iterator database:(Database *)database {
    if ((self = [super init]) != nil) {
        iterator_ = iterator;
        database_ = database;

        version_ = [database_ policy]->GetCandidateVer(iterator_);
        latest_ = version_.end() ? nil : [[NSString stringWithUTF8String:version_.VerStr()] retain];

        if (!version_.end())
            file_ = version_.FileList();
        else {
            pkgCache &cache([database_ cache]);
            file_ = pkgCache::VerFileIterator(cache, cache.VerFileP);
        }

        pkgCache::VerIterator current = iterator_.CurrentVer();
        installed_ = current.end() ? nil : [[NSString stringWithUTF8String:current.VerStr()] retain];

        id_ = [[[NSString stringWithUTF8String:iterator_.Name()] lowercaseString] retain];

        if (!file_.end()) {
            pkgRecords::Parser *parser = &[database_ records]->Lookup(file_);

            const char *begin, *end;
            parser->GetRec(begin, end);

            name_ = Scour("Name", begin, end);
            if (name_ != nil)
                name_ = [name_ retain];
            tagline_ = [[NSString stringWithUTF8String:parser->ShortDesc().c_str()] retain];
            icon_ = Scour("Icon", begin, end);
            if (icon_ != nil)
                icon_ = [icon_ retain];
            website_ = Scour("Homepage", begin, end);
            if (website_ == nil)
                website_ = Scour("Website", begin, end);
            if (website_ != nil)
                website_ = [website_ retain];
            NSString *author = Scour("Author", begin, end);
            if (author != nil)
                author_ = [Address addressWithString:author];
        }

        NSMutableDictionary *metadata = [Packages_ objectForKey:id_];
        if (metadata == nil || [metadata count] == 0) {
            metadata = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                now_, @"FirstSeen",
            nil];

            [Packages_ setObject:metadata forKey:id_];
            Changed_ = true;
        }
    } return self;
}

+ (Package *) packageWithIterator:(pkgCache::PkgIterator)iterator database:(Database *)database {
    return [[[Package alloc]
        initWithIterator:iterator 
        database:database
    ] autorelease];
}

- (pkgCache::PkgIterator) iterator {
    return iterator_;
}

- (NSString *) section {
    const char *section = iterator_.Section();
    return section == NULL ? nil : [[NSString stringWithUTF8String:section] stringByReplacingCharacter:'_' withCharacter:' '];
}

- (Address *) maintainer {
    if (file_.end())
        return nil;
    pkgRecords::Parser *parser = &[database_ records]->Lookup(file_);
    return [Address addressWithString:[NSString stringWithUTF8String:parser->Maintainer().c_str()]];
}

- (size_t) size {
    return version_.end() ? 0 : version_->InstalledSize;
}

- (NSString *) description {
    if (file_.end())
        return nil;
    pkgRecords::Parser *parser = &[database_ records]->Lookup(file_);
    NSString *description([NSString stringWithUTF8String:parser->LongDesc().c_str()]);

    NSArray *lines = [description componentsSeparatedByString:@"\n"];
    NSMutableArray *trimmed = [NSMutableArray arrayWithCapacity:([lines count] - 1)];
    if ([lines count] < 2)
        return nil;

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
    for (size_t i(1); i != [lines count]; ++i) {
        NSString *trim = [[lines objectAtIndex:i] stringByTrimmingCharactersInSet:whitespace];
        [trimmed addObject:trim];
    }

    return [trimmed componentsJoinedByString:@"\n"];
}

- (NSString *) index {
    NSString *index = [[[self name] substringToIndex:1] uppercaseString];
    return [index length] != 0 && isalpha([index characterAtIndex:0]) ? index : @"123";
}

- (NSDate *) seen {
    return [[Packages_ objectForKey:id_] objectForKey:@"FirstSeen"];
}

- (NSString *) latest {
    return latest_;
}

- (NSString *) installed {
    return installed_;
}

- (BOOL) valid {
    return !version_.end();
}

- (BOOL) upgradable {
    pkgCache::VerIterator current = iterator_.CurrentVer();

    if (current.end())
        return [self essential];
    else {
        pkgCache::VerIterator candidate = [database_ policy]->GetCandidateVer(iterator_);
        return !candidate.end() && candidate != current;
    }
}

- (BOOL) essential {
    return (iterator_->Flags & pkgCache::Flag::Essential) == 0 ? NO : YES;
}

- (BOOL) broken {
    return [database_ cache][iterator_].InstBroken();
}

- (BOOL) half {
    unsigned char current = iterator_->CurrentState;
    return current == pkgCache::State::HalfConfigured || current == pkgCache::State::HalfInstalled;
}

- (BOOL) halfConfigured {
    return iterator_->CurrentState == pkgCache::State::HalfConfigured;
}

- (BOOL) halfInstalled {
    return iterator_->CurrentState == pkgCache::State::HalfInstalled;
}

- (BOOL) hasMode {
    pkgDepCache::StateCache &state([database_ cache][iterator_]);
    return state.Mode != pkgDepCache::ModeKeep;
}

- (NSString *) mode {
    pkgDepCache::StateCache &state([database_ cache][iterator_]);

    switch (state.Mode) {
        case pkgDepCache::ModeDelete:
            if ((state.iFlags & pkgDepCache::Purge) != 0)
                return @"Purge";
            else
                return @"Remove";
            _assert(false);
        case pkgDepCache::ModeKeep:
            if ((state.iFlags & pkgDepCache::AutoKept) != 0)
                return nil;
            else
                return nil;
            _assert(false);
        case pkgDepCache::ModeInstall:
            if ((state.iFlags & pkgDepCache::ReInstall) != 0)
                return @"Reinstall";
            else switch (state.Status) {
                case -1:
                    return @"Downgrade";
                case 0:
                    return @"Install";
                case 1:
                    return @"Upgrade";
                case 2:
                    return @"New Install";
                default:
                    _assert(false);
            }
        default:
            _assert(false);
    }
}

- (NSString *) id {
    return id_;
}

- (NSString *) name {
    return name_ == nil ? id_ : name_;
}

- (NSString *) tagline {
    return tagline_;
}

- (NSString *) icon {
    return icon_;
}

- (NSString *) website {
    return website_;
}

- (Address *) author {
    return author_;
}

- (NSArray *) relationships {
    return relationships_;
}

- (Source *) source {
    if (!cached_) {
        source_ = file_.end() ? nil : [[database_ getSource:file_.File()] retain];
        cached_ = true;
    }

    return source_;
}

- (BOOL) matches:(NSString *)text {
    if (text == nil)
        return NO;

    NSRange range;

    range = [[self id] rangeOfString:text options:NSCaseInsensitiveSearch];
    if (range.location != NSNotFound)
        return YES;

    range = [[self name] rangeOfString:text options:NSCaseInsensitiveSearch];
    if (range.location != NSNotFound)
        return YES;

    range = [[self tagline] rangeOfString:text options:NSCaseInsensitiveSearch];
    if (range.location != NSNotFound)
        return YES;

    return NO;
}

- (NSComparisonResult) compareByName:(Package *)package {
    NSString *lhs = [self name];
    NSString *rhs = [package name];

    if ([lhs length] != 0 && [rhs length] != 0) {
        unichar lhc = [lhs characterAtIndex:0];
        unichar rhc = [rhs characterAtIndex:0];

        if (isalpha(lhc) && !isalpha(rhc))
            return NSOrderedAscending;
        else if (!isalpha(lhc) && isalpha(rhc))
            return NSOrderedDescending;
    }

    return [lhs caseInsensitiveCompare:rhs];
}

- (NSComparisonResult) compareBySection:(Package *)package {
    NSString *lhs = [self section];
    NSString *rhs = [package section];

    if (lhs == NULL && rhs != NULL)
        return NSOrderedAscending;
    else if (lhs != NULL && rhs == NULL)
        return NSOrderedDescending;
    else if (lhs != NULL && rhs != NULL) {
        NSComparisonResult result = [lhs caseInsensitiveCompare:rhs];
        if (result != NSOrderedSame)
            return result;
    }

    return NSOrderedSame;
}

- (NSComparisonResult) compareBySectionAndName:(Package *)package {
    NSString *lhs = [self section];
    NSString *rhs = [package section];

    if (lhs == NULL && rhs != NULL)
        return NSOrderedAscending;
    else if (lhs != NULL && rhs == NULL)
        return NSOrderedDescending;
    else if (lhs != NULL && rhs != NULL) {
        NSComparisonResult result = [lhs compare:rhs];
        if (result != NSOrderedSame)
            return result;
    }

    return [self compareByName:package];
}

- (NSComparisonResult) compareForChanges:(Package *)package {
    BOOL lhs = [self upgradable];
    BOOL rhs = [package upgradable];

    if (lhs != rhs)
        return lhs ? NSOrderedAscending : NSOrderedDescending;
    else if (!lhs) {
        switch ([[self seen] compare:[package seen]]) {
            case NSOrderedAscending:
                return NSOrderedDescending;
            case NSOrderedSame:
                break;
            case NSOrderedDescending:
                return NSOrderedAscending;
            default:
                _assert(false);
        }
    }

    return [self compareByName:package];
}

- (void) install {
    pkgProblemResolver *resolver = [database_ resolver];
    resolver->Clear(iterator_);
    resolver->Protect(iterator_);
    pkgCacheFile &cache([database_ cache]);
    cache->MarkInstall(iterator_, false);
    pkgDepCache::StateCache &state((*cache)[iterator_]);
    if (!state.Install())
        cache->SetReInstall(iterator_, true);
}

- (void) remove {
    pkgProblemResolver *resolver = [database_ resolver];
    resolver->Clear(iterator_);
    resolver->Protect(iterator_);
    resolver->Remove(iterator_);
    [database_ cache]->MarkDelete(iterator_, true);
}

- (NSNumber *) isSearchedForBy:(NSString *)search {
    return [NSNumber numberWithBool:([self valid] && [self matches:search])];
}

- (NSNumber *) isInstalledInSection:(NSString *)section {
    return [NSNumber numberWithBool:([self installed] != nil && (section == nil || [section isEqualToString:[self section]]))];
}

- (NSNumber *) isUninstalledInSection:(NSString *)name {
    NSString *section = [self section];

    return [NSNumber numberWithBool:([self valid] && [self installed] == nil && (
        (name == nil ||
        section == nil && [name length] == 0 ||
        [name isEqualToString:section])
    ))];
}

@end
/* }}} */
/* Section Class {{{ */
@interface Section : NSObject {
    NSString *name_;
    size_t row_;
    size_t count_;
}

- (Section *) initWithName:(NSString *)name row:(size_t)row;
- (NSString *) name;
- (size_t) row;
- (size_t) count;
- (void) addToCount;

@end

@implementation Section

- (void) dealloc {
    [name_ release];
    [super dealloc];
}

- (Section *) initWithName:(NSString *)name row:(size_t)row {
    if ((self = [super init]) != nil) {
        name_ = [name retain];
        row_ = row;
    } return self;
}

- (NSString *) name {
    return name_;
}

- (size_t) row {
    return row_;
}

- (size_t) count {
    return count_;
}

- (void) addToCount {
    ++count_;
}

@end
/* }}} */

/* Database Implementation {{{ */
@implementation Database

- (void) dealloc {
    _assert(false);
    [super dealloc];
}

- (void) _readCydia:(NSNumber *)fd {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    __gnu_cxx::stdio_filebuf<char> ib([fd intValue], std::ios::in);
    std::istream is(&ib);
    std::string line;

    while (std::getline(is, line)) {
        const char *data(line.c_str());
        //size_t size = line.size();
        fprintf(stderr, "C:%s\n", data);
    }

    [pool release];
    _assert(false);
}

- (void) _readStatus:(NSNumber *)fd {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    __gnu_cxx::stdio_filebuf<char> ib([fd intValue], std::ios::in);
    std::istream is(&ib);
    std::string line;

    Pcre conffile_r("^status: [^ ]* : conffile-prompt : (.*?) *$");
    Pcre pmstatus_r("^([^:]*):([^:]*):([^:]*):(.*)$");

    while (std::getline(is, line)) {
        const char *data(line.c_str());
        size_t size = line.size();
        fprintf(stderr, "S:%s\n", data);

        if (conffile_r(data, size)) {
            [delegate_ setConfigurationData:conffile_r[1]];
        } else if (strncmp(data, "status: ", 8) == 0) {
            NSString *string = [NSString stringWithUTF8String:(data + 8)];
            [delegate_ setProgressTitle:string];
        } else if (pmstatus_r(data, size)) {
            float percent([pmstatus_r[3] floatValue]);
            [delegate_ setProgressPercent:(percent / 100)];

            NSString *string = pmstatus_r[4];
            std::string type([pmstatus_r[1] UTF8String]);

            if (type == "pmerror")
                [delegate_ setProgressError:string];
            else if (type == "pmstatus")
                [delegate_ setProgressTitle:string];
            else if (type == "pmconffile")
                [delegate_ setConfigurationData:string];
            else _assert(false);
        } else _assert(false);
    }

    [pool release];
    _assert(false);
}

- (void) _readOutput:(NSNumber *)fd {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    __gnu_cxx::stdio_filebuf<char> ib([fd intValue], std::ios::in);
    std::istream is(&ib);
    std::string line;

    while (std::getline(is, line)) {
        fprintf(stderr, "O:%s\n", line.c_str());
        [delegate_ addProgressOutput:[NSString stringWithUTF8String:line.c_str()]];
    }

    [pool release];
    _assert(false);
}

- (FILE *) input {
    return input_;
}

- (Package *) packageWithName:(NSString *)name {
    if (static_cast<pkgDepCache *>(cache_) == NULL)
        return nil;
    pkgCache::PkgIterator iterator(cache_->FindPkg([name UTF8String]));
    return iterator.end() ? nil : [Package packageWithIterator:iterator database:self];
}

- (Database *) init {
    if ((self = [super init]) != nil) {
        policy_ = NULL;
        records_ = NULL;
        resolver_ = NULL;
        fetcher_ = NULL;
        lock_ = NULL;

        sources_ = [[NSMutableDictionary dictionaryWithCapacity:16] retain];
        packages_ = [[NSMutableArray arrayWithCapacity:16] retain];

        int fds[2];

        _assert(pipe(fds) != -1);
        cydiafd_ = fds[1];

        _config->Set("APT::Keep-Fds::", cydiafd_);
        setenv("CYDIA", [[[[NSNumber numberWithInt:cydiafd_] stringValue] stringByAppendingString:@" 0"] UTF8String], _not(int));

        [NSThread
            detachNewThreadSelector:@selector(_readCydia:)
            toTarget:self
            withObject:[[NSNumber numberWithInt:fds[0]] retain]
        ];

        _assert(pipe(fds) != -1);
        statusfd_ = fds[1];

        [NSThread
            detachNewThreadSelector:@selector(_readStatus:)
            toTarget:self
            withObject:[[NSNumber numberWithInt:fds[0]] retain]
        ];

        _assert(pipe(fds) != -1);
        _assert(dup2(fds[0], 0) != -1);
        _assert(close(fds[0]) != -1);

        input_ = fdopen(fds[1], "a");

        _assert(pipe(fds) != -1);
        _assert(dup2(fds[1], 1) != -1);
        _assert(close(fds[1]) != -1);

        [NSThread
            detachNewThreadSelector:@selector(_readOutput:)
            toTarget:self
            withObject:[[NSNumber numberWithInt:fds[0]] retain]
        ];
    } return self;
}

- (pkgCacheFile &) cache {
    return cache_;
}

- (pkgDepCache::Policy *) policy {
    return policy_;
}

- (pkgRecords *) records {
    return records_;
}

- (pkgProblemResolver *) resolver {
    return resolver_;
}

- (pkgAcquire &) fetcher {
    return *fetcher_;
}

- (NSArray *) packages {
    return packages_;
}

- (void) reloadData {
    _error->Discard();

    delete list_;
    list_ = NULL;
    manager_ = NULL;
    delete lock_;
    lock_ = NULL;
    delete fetcher_;
    fetcher_ = NULL;
    delete resolver_;
    resolver_ = NULL;
    delete records_;
    records_ = NULL;
    delete policy_;
    policy_ = NULL;

    cache_.Close();

    if (!cache_.Open(progress_, true)) {
        std::string error;
        if (!_error->PopMessage(error))
            _assert(false);
        _error->Discard();
        fprintf(stderr, "cache_.Open():[%s]\n", error.c_str());

        if (error == "dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem. ")
            [delegate_ repairWithSelector:@selector(configure)];
        else if (error == "The package lists or status file could not be parsed or opened.")
            [delegate_ repairWithSelector:@selector(update)];
        // else if (error == "Could not open lock file /var/lib/dpkg/lock - open (13 Permission denied)")
        // else if (error == "Could not get lock /var/lib/dpkg/lock - open (35 Resource temporarily unavailable)")
        // else if (error == "The list of sources could not be read.")
        else _assert(false);

        return;
    }

    now_ = [[NSDate date] retain];

    policy_ = new pkgDepCache::Policy();
    records_ = new pkgRecords(cache_);
    resolver_ = new pkgProblemResolver(cache_);
    fetcher_ = new pkgAcquire(&status_);
    lock_ = NULL;

    list_ = new pkgSourceList();
    _assert(list_->ReadMainList());

    _assert(cache_->DelCount() == 0 && cache_->InstCount() == 0);
    _assert(pkgApplyStatus(cache_));

    if (cache_->BrokenCount() != 0) {
        _assert(pkgFixBroken(cache_));
        _assert(cache_->BrokenCount() == 0);
        _assert(pkgMinimizeUpgrade(cache_));
    }

    [sources_ removeAllObjects];
    for (pkgSourceList::const_iterator source = list_->begin(); source != list_->end(); ++source) {
        std::vector<pkgIndexFile *> *indices = (*source)->GetIndexFiles();
        for (std::vector<pkgIndexFile *>::const_iterator index = indices->begin(); index != indices->end(); ++index)
            [sources_
                setObject:[[[Source alloc] initWithMetaIndex:*source] autorelease]
                forKey:[NSNumber numberWithLong:reinterpret_cast<uintptr_t>(*index)]
            ];
    }

    [packages_ removeAllObjects];
    for (pkgCache::PkgIterator iterator = cache_->PkgBegin(); !iterator.end(); ++iterator)
        if (Package *package = [Package packageWithIterator:iterator database:self])
            [packages_ addObject:package];

    [packages_ sortUsingSelector:@selector(compareByName:)];
}

- (void) configure {
    NSString *dpkg = [NSString stringWithFormat:@"dpkg --configure -a --status-fd %u", statusfd_];
    system([dpkg UTF8String]);
}

- (void) clean {
    if (lock_ != NULL)
        return;

    FileFd Lock;
    Lock.Fd(GetLock(_config->FindDir("Dir::Cache::Archives") + "lock"));
    _assert(!_error->PendingError());

    pkgAcquire fetcher;
    fetcher.Clean(_config->FindDir("Dir::Cache::Archives"));

    class LogCleaner :
        public pkgArchiveCleaner
    {
      protected:
        virtual void Erase(const char *File, std::string Pkg, std::string Ver, struct stat &St) {
            unlink(File);
        }
    } cleaner;

    if (!cleaner.Go(_config->FindDir("Dir::Cache::Archives") + "partial/", cache_)) {
        std::string error;
        while (_error->PopMessage(error))
            fprintf(stderr, "ArchiveCleaner: %s\n", error.c_str());
    }
}

- (void) prepare {
    pkgRecords records(cache_);

    lock_ = new FileFd();
    lock_->Fd(GetLock(_config->FindDir("Dir::Cache::Archives") + "lock"));
    _assert(!_error->PendingError());

    pkgSourceList list;
    // XXX: explain this with an error message
    _assert(list.ReadMainList());

    manager_ = (_system->CreatePM(cache_));
    _assert(manager_->GetArchives(fetcher_, &list, &records));
    _assert(!_error->PendingError());
}

- (void) perform {
    NSMutableArray *before = [NSMutableArray arrayWithCapacity:16]; {
        pkgSourceList list;
        _assert(list.ReadMainList());
        for (pkgSourceList::const_iterator source = list.begin(); source != list.end(); ++source)
            [before addObject:[NSString stringWithUTF8String:(*source)->GetURI().c_str()]];
    }

    if (fetcher_->Run(PulseInterval_) != pkgAcquire::Continue)
        return;

    _system->UnLock();
    pkgPackageManager::OrderResult result = manager_->DoInstall(statusfd_);

    if (result == pkgPackageManager::Failed)
        return;
    if (_error->PendingError())
        return;
    if (result != pkgPackageManager::Completed)
        return;

    NSMutableArray *after = [NSMutableArray arrayWithCapacity:16]; {
        pkgSourceList list;
        _assert(list.ReadMainList());
        for (pkgSourceList::const_iterator source = list.begin(); source != list.end(); ++source)
            [after addObject:[NSString stringWithUTF8String:(*source)->GetURI().c_str()]];
    }

    if (![before isEqualToArray:after])
        [self update];
}

- (void) upgrade {
    _assert(pkgDistUpgrade(cache_));
}

- (void) update {
    [self updateWithStatus:status_];
}

- (void) updateWithStatus:(Status &)status {
    pkgSourceList list;
    _assert(list.ReadMainList());

    FileFd lock;
    lock.Fd(GetLock(_config->FindDir("Dir::State::Lists") + "lock"));
    _assert(!_error->PendingError());

    pkgAcquire fetcher(&status);
    _assert(list.GetIndexes(&fetcher));

    if (fetcher.Run(PulseInterval_) != pkgAcquire::Failed) {
        bool failed = false;
        for (pkgAcquire::ItemIterator item = fetcher.ItemsBegin(); item != fetcher.ItemsEnd(); item++)
            if ((*item)->Status != pkgAcquire::Item::StatDone) {
                (*item)->Finished();
                failed = true;
            }

        if (!failed && _config->FindB("APT::Get::List-Cleanup", true) == true) {
            _assert(fetcher.Clean(_config->FindDir("Dir::State::lists")));
            _assert(fetcher.Clean(_config->FindDir("Dir::State::lists") + "partial/"));
        }

        [Metadata_ setObject:[NSDate date] forKey:@"LastUpdate"];
        Changed_ = true;
    }
}

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
    status_.setDelegate(delegate);
    progress_.setDelegate(delegate);
}

- (Source *) getSource:(const pkgCache::PkgFileIterator &)file {
    pkgIndexFile *index(NULL);
    list_->FindIndex(file, index);
    return [sources_ objectForKey:[NSNumber numberWithLong:reinterpret_cast<uintptr_t>(index)]];
}

@end
/* }}} */

/* Confirmation View {{{ */
void AddTextView(NSMutableDictionary *fields, NSMutableArray *packages, NSString *key) {
    if ([packages count] == 0)
        return;

    UITextView *text = GetTextView([packages count] == 0 ? @"n/a" : [packages componentsJoinedByString:@", "], 120, false);
    [fields setObject:text forKey:key];

    CGColor blue(space_, 0, 0, 0.4, 1);
    [text setTextColor:blue];
}

@protocol ConfirmationViewDelegate
- (void) cancel;
- (void) confirm;
@end

@interface ConfirmationView : UIView {
    Database *database_;
    id delegate_;
    UITransitionView *transition_;
    UIView *overlay_;
    UINavigationBar *navbar_;
    UIPreferencesTable *table_;
    NSMutableDictionary *fields_;
    UIAlertSheet *essential_;
}

- (void) cancel;

- (id) initWithView:(UIView *)view database:(Database *)database delegate:(id)delegate;

@end

@implementation ConfirmationView

- (void) dealloc {
    [navbar_ setDelegate:nil];
    [transition_ setDelegate:nil];
    [table_ setDataSource:nil];

    [transition_ release];
    [overlay_ release];
    [navbar_ release];
    [table_ release];
    [fields_ release];
    if (essential_ != nil)
        [essential_ release];
    [super dealloc];
}

- (void) cancel {
    [transition_ transition:7 toView:nil];
    [delegate_ cancel];
}

- (void) transitionViewDidComplete:(UITransitionView*)view fromView:(UIView*)from toView:(UIView*)to {
    if (from != nil && to == nil)
        [self removeFromSuperview];
}

- (void) navigationBar:(UINavigationBar *)navbar buttonClicked:(int)button {
    switch (button) {
        case 0:
            if (essential_ != nil)
                [essential_ popupAlertAnimated:YES];
            else
                [delegate_ confirm];
        break;

        case 1:
            [self cancel];
        break;
    }
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    NSString *context = [sheet context];

    if ([context isEqualToString:@"remove"])
        switch (button) {
            case 1:
                [delegate_ confirm];
                break;
            case 2:
                [self cancel];
                break;
            default:
                _assert(false);
        }
    else if ([context isEqualToString:@"unable"])
        [self cancel];

    [sheet dismiss];
}

- (int) numberOfGroupsInPreferencesTable:(UIPreferencesTable *)table {
    return 2;
}

- (NSString *) preferencesTable:(UIPreferencesTable *)table titleForGroup:(int)group {
    switch (group) {
        case 0: return @"Statistics";
        case 1: return @"Modifications";

        default: _assert(false);
    }
}

- (int) preferencesTable:(UIPreferencesTable *)table numberOfRowsInGroup:(int)group {
    switch (group) {
        case 0: return 3;
        case 1: return [fields_ count];

        default: _assert(false);
    }
}

- (float) preferencesTable:(UIPreferencesTable *)table heightForRow:(int)row inGroup:(int)group withProposedHeight:(float)proposed {
    if (group != 1 || row == -1)
        return proposed;
    else {
        _assert(size_t(row) < [fields_ count]);
        return [[[fields_ allValues] objectAtIndex:row] visibleTextRect].size.height + TextViewOffset_;
    }
}

- (UIPreferencesTableCell *) preferencesTable:(UIPreferencesTable *)table cellForRow:(int)row inGroup:(int)group {
    UIPreferencesTableCell *cell = [[[UIPreferencesTableCell alloc] init] autorelease];
    [cell setShowSelection:NO];

    switch (group) {
        case 0: switch (row) {
            case 0: {
                [cell setTitle:@"Downloading"];
                [cell setValue:SizeString([database_ fetcher].FetchNeeded())];
            } break;

            case 1: {
                [cell setTitle:@"Resuming At"];
                [cell setValue:SizeString([database_ fetcher].PartialPresent())];
            } break;

            case 2: {
                double size([database_ cache]->UsrSize());

                if (size < 0) {
                    [cell setTitle:@"Disk Freeing"];
                    [cell setValue:SizeString(-size)];
                } else {
                    [cell setTitle:@"Disk Using"];
                    [cell setValue:SizeString(size)];
                }
            } break;

            default: _assert(false);
        } break;

        case 1:
            _assert(size_t(row) < [fields_ count]);
            [cell setTitle:[[fields_ allKeys] objectAtIndex:row]];
            [cell addSubview:[[fields_ allValues] objectAtIndex:row]];
        break;

        default: _assert(false);
    }

    return cell;
}

- (id) initWithView:(UIView *)view database:(Database *)database delegate:(id)delegate {
    if ((self = [super initWithFrame:[view bounds]]) != nil) {
        database_ = database;
        delegate_ = delegate;

        transition_ = [[UITransitionView alloc] initWithFrame:[self bounds]];
        [self addSubview:transition_];

        overlay_ = [[UIView alloc] initWithFrame:[transition_ bounds]];

        CGSize navsize = [UINavigationBar defaultSize];
        CGRect navrect = {{0, 0}, navsize};
        CGRect bounds = [overlay_ bounds];

        navbar_ = [[UINavigationBar alloc] initWithFrame:navrect];
        if (Advanced_)
            [navbar_ setBarStyle:1];
        [navbar_ setDelegate:self];

        UINavigationItem *navitem = [[[UINavigationItem alloc] initWithTitle:@"Confirm"] autorelease];
        [navbar_ pushNavigationItem:navitem];
        [navbar_ showButtonsWithLeftTitle:@"Cancel" rightTitle:@"Confirm"];

        fields_ = [[NSMutableDictionary dictionaryWithCapacity:16] retain];

        NSMutableArray *installing = [NSMutableArray arrayWithCapacity:16];
        NSMutableArray *reinstalling = [NSMutableArray arrayWithCapacity:16];
        NSMutableArray *upgrading = [NSMutableArray arrayWithCapacity:16];
        NSMutableArray *downgrading = [NSMutableArray arrayWithCapacity:16];
        NSMutableArray *removing = [NSMutableArray arrayWithCapacity:16];

        bool remove(false);

        pkgCacheFile &cache([database_ cache]);
        NSArray *packages = [database_ packages];
        for (size_t i(0), e = [packages count]; i != e; ++i) {
            Package *package = [packages objectAtIndex:i];
            pkgCache::PkgIterator iterator = [package iterator];
            pkgDepCache::StateCache &state(cache[iterator]);

            NSString *name([package name]);

            if (state.NewInstall())
                [installing addObject:name];
            else if (!state.Delete() && (state.iFlags & pkgDepCache::ReInstall) == pkgDepCache::ReInstall)
                [reinstalling addObject:name];
            else if (state.Upgrade())
                [upgrading addObject:name];
            else if (state.Downgrade())
                [downgrading addObject:name];
            else if (state.Delete()) {
                if ([package essential])
                    remove = true;
                [removing addObject:name];
            }
        }

        if (!remove)
            essential_ = nil;
        else if (Advanced_ || true) {
            essential_ = [[UIAlertSheet alloc]
                initWithTitle:@"Remove Essential?"
                buttons:[NSArray arrayWithObjects:
                    @"Yes (Force Removal)",
                    @"No (Safe, Recommended)",
                nil]
                defaultButtonIndex:1
                delegate:self
                context:@"remove"
            ];

            [essential_ setDestructiveButton:[[essential_ buttons] objectAtIndex:0]];
            [essential_ setBodyText:@"This operation requires the removal of one or more packages that are required for the continued operation of either Cydia or the iPhoneOS. If you continue you will almost certainly break something past Cydia's ability to fix it. Are you absolutely certain you wish to continue?"];
        } else {
            essential_ = [[UIAlertSheet alloc]
                initWithTitle:@"Unable to Comply"
                buttons:[NSArray arrayWithObjects:@"Okay", nil]
                defaultButtonIndex:0
                delegate:self
                context:@"unable"
            ];

            [essential_ setBodyText:@"This operation requires the removal of one or more packages that are required for the continued operation of either Cydia or the iPhoneOS. In order to continue and force this operation you will need to be activate the Advanced mode undder to continue and force this operation you will need to be activate the Advanced mode under Settings."];
        }

        AddTextView(fields_, installing, @"Installing");
        AddTextView(fields_, reinstalling, @"Reinstalling");
        AddTextView(fields_, upgrading, @"Upgrading");
        AddTextView(fields_, downgrading, @"Downgrading");
        AddTextView(fields_, removing, @"Removing");

        table_ = [[UIPreferencesTable alloc] initWithFrame:CGRectMake(
            0, navsize.height, bounds.size.width, bounds.size.height - navsize.height
        )];

        [table_ setReusesTableCells:YES];
        [table_ setDataSource:self];
        [table_ reloadData];

        [overlay_ addSubview:navbar_];
        [overlay_ addSubview:table_];

        [view addSubview:self];

        [transition_ setDelegate:self];

        UIView *blank = [[[UIView alloc] initWithFrame:[transition_ bounds]] autorelease];
        [transition_ transition:0 toView:blank];
        [transition_ transition:3 toView:overlay_];
    } return self;
}

@end
/* }}} */

/* Progress Data {{{ */
@interface ProgressData : NSObject {
    SEL selector_;
    id target_;
    id object_;
}

- (ProgressData *) initWithSelector:(SEL)selector target:(id)target object:(id)object;

- (SEL) selector;
- (id) target;
- (id) object;
@end

@implementation ProgressData

- (ProgressData *) initWithSelector:(SEL)selector target:(id)target object:(id)object {
    if ((self = [super init]) != nil) {
        selector_ = selector;
        target_ = target;
        object_ = object;
    } return self;
}

- (SEL) selector {
    return selector_;
}

- (id) target {
    return target_;
}

- (id) object {
    return object_;
}

@end
/* }}} */
/* Progress View {{{ */
Pcre conffile_r("^'(.*)' '(.*)' ([01]) ([01])$");

@interface ProgressView : UIView <
    ConfigurationDelegate,
    ProgressDelegate
> {
    _transient Database *database_;
    UIView *view_;
    UIView *background_;
    UITransitionView *transition_;
    UIView *overlay_;
    UINavigationBar *navbar_;
    UIProgressBar *progress_;
    UITextView *output_;
    UITextLabel *status_;
    id delegate_;
}

- (void) transitionViewDidComplete:(UITransitionView*)view fromView:(UIView*)from toView:(UIView*)to;

- (id) initWithFrame:(struct CGRect)frame database:(Database *)database delegate:(id)delegate;
- (void) setContentView:(UIView *)view;
- (void) resetView;

- (void) _retachThread;
- (void) _detachNewThreadData:(ProgressData *)data;
- (void) detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)object title:(NSString *)title;

@end

@protocol ProgressViewDelegate
- (void) progressViewIsComplete:(ProgressView *)sender;
@end

@implementation ProgressView

- (void) dealloc {
    [transition_ setDelegate:nil];
    [navbar_ setDelegate:nil];

    [view_ release];
    if (background_ != nil)
        [background_ release];
    [transition_ release];
    [overlay_ release];
    [navbar_ release];
    [progress_ release];
    [output_ release];
    [status_ release];
    [super dealloc];
}

- (void) transitionViewDidComplete:(UITransitionView*)view fromView:(UIView*)from toView:(UIView*)to {
    if (bootstrap_ && from == overlay_ && to == view_)
        exit(0);
}

- (id) initWithFrame:(struct CGRect)frame database:(Database *)database delegate:(id)delegate {
    if ((self = [super initWithFrame:frame]) != nil) {
        database_ = database;
        delegate_ = delegate;

        transition_ = [[UITransitionView alloc] initWithFrame:[self bounds]];
        [transition_ setDelegate:self];

        overlay_ = [[UIView alloc] initWithFrame:[transition_ bounds]];

        if (bootstrap_)
            [overlay_ setBackgroundColor:Black_];
        else {
            background_ = [[UIView alloc] initWithFrame:[self bounds]];
            [background_ setBackgroundColor:Black_];
            [self addSubview:background_];
        }

        [self addSubview:transition_];

        CGSize navsize = [UINavigationBar defaultSize];
        CGRect navrect = {{0, 0}, navsize};

        navbar_ = [[UINavigationBar alloc] initWithFrame:navrect];
        [overlay_ addSubview:navbar_];

        [navbar_ setBarStyle:1];
        [navbar_ setDelegate:self];

        UINavigationItem *navitem = [[[UINavigationItem alloc] initWithTitle:nil] autorelease];
        [navbar_ pushNavigationItem:navitem];

        CGRect bounds = [overlay_ bounds];
        CGSize prgsize = [UIProgressBar defaultSize];

        CGRect prgrect = {{
            (bounds.size.width - prgsize.width) / 2,
            bounds.size.height - prgsize.height - 20
        }, prgsize};

        progress_ = [[UIProgressBar alloc] initWithFrame:prgrect];
        [overlay_ addSubview:progress_];

        status_ = [[UITextLabel alloc] initWithFrame:CGRectMake(
            10,
            bounds.size.height - prgsize.height - 50,
            bounds.size.width - 20,
            24
        )];

        [status_ setColor:White_];
        [status_ setBackgroundColor:Clear_];

        [status_ setCentersHorizontally:YES];
        //[status_ setFont:font];

        output_ = [[UITextView alloc] initWithFrame:CGRectMake(
            10,
            navrect.size.height + 20,
            bounds.size.width - 20,
            bounds.size.height - navsize.height - 62 - navrect.size.height
        )];

        //[output_ setTextFont:@"Courier New"];
        [output_ setTextSize:12];

        [output_ setTextColor:White_];
        [output_ setBackgroundColor:Clear_];

        [output_ setMarginTop:0];
        [output_ setAllowsRubberBanding:YES];

        [overlay_ addSubview:output_];
        [overlay_ addSubview:status_];

        [progress_ setStyle:0];
    } return self;
}

- (void) setContentView:(UIView *)view {
    view_ = [view retain];
}

- (void) resetView {
    [transition_ transition:6 toView:view_];
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    NSString *context = [sheet context];
    if ([context isEqualToString:@"conffile"]) {
        FILE *input = [database_ input];

        switch (button) {
            case 1:
                fprintf(input, "N\n");
                fflush(input);
                break;
            case 2:
                fprintf(input, "Y\n");
                fflush(input);
                break;
            default:
                _assert(false);
        }
    }

    [sheet dismiss];
}

- (void) _retachThread {
    [delegate_ progressViewIsComplete:self];
    [self resetView];
}

- (void) _detachNewThreadData:(ProgressData *)data {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    [[data target] performSelector:[data selector] withObject:[data object]];
    [data release];

    [self performSelectorOnMainThread:@selector(_retachThread) withObject:nil waitUntilDone:YES];

    [pool release];
}

- (void) detachNewThreadSelector:(SEL)selector toTarget:(id)target withObject:(id)object title:(NSString *)title {
    UINavigationItem *item = [navbar_ topItem];
    [item setTitle:title];

    [status_ setText:nil];
    [output_ setText:@""];
    [progress_ setProgress:0];

    [transition_ transition:6 toView:overlay_];

    [NSThread
        detachNewThreadSelector:@selector(_detachNewThreadData:)
        toTarget:self
        withObject:[[ProgressData alloc]
            initWithSelector:selector
            target:target
            object:object
        ]
    ];
}

- (void) repairWithSelector:(SEL)selector {
    [self
        detachNewThreadSelector:selector
        toTarget:database_
        withObject:nil
        title:@"Repairing..."
    ];
}

- (void) setConfigurationData:(NSString *)data {
    [self
        performSelectorOnMainThread:@selector(_setConfigurationData:)
        withObject:data
        waitUntilDone:YES
    ];
}

- (void) setProgressError:(NSString *)error {
    [self
        performSelectorOnMainThread:@selector(_setProgressError:)
        withObject:error
        waitUntilDone:YES
    ];
}

- (void) setProgressTitle:(NSString *)title {
    [self
        performSelectorOnMainThread:@selector(_setProgressTitle:)
        withObject:title
        waitUntilDone:YES
    ];
}

- (void) setProgressPercent:(float)percent {
    [self
        performSelectorOnMainThread:@selector(_setProgressPercent:)
        withObject:[NSNumber numberWithFloat:percent]
        waitUntilDone:YES
    ];
}

- (void) addProgressOutput:(NSString *)output {
    [self
        performSelectorOnMainThread:@selector(_addProgressOutput:)
        withObject:output
        waitUntilDone:YES
    ];
}

- (void) _setConfigurationData:(NSString *)data {
    _assert(conffile_r(data));

    NSString *ofile = conffile_r[1];
    //NSString *nfile = conffile_r[2];

    UIAlertSheet *sheet = [[[UIAlertSheet alloc]
        initWithTitle:@"Configuration Upgrade"
        buttons:[NSArray arrayWithObjects:
            @"Keep My Old Copy",
            @"Accept The New Copy",
            // XXX: @"See What Changed",
        nil]
        defaultButtonIndex:0
        delegate:self
        context:@"conffile"
    ] autorelease];

    [sheet setBodyText:[NSString stringWithFormat:
        @"The following file has been changed by both the package maintainer and by you (or for you by a script).\n\n%@"
    , ofile]];

    [sheet popupAlertAnimated:YES];
}

- (void) _setProgressError:(NSString *)error {
    UIAlertSheet *sheet = [[[UIAlertSheet alloc]
        initWithTitle:@"Package Error"
        buttons:[NSArray arrayWithObjects:@"Okay", nil]
        defaultButtonIndex:0
        delegate:self
        context:@"error"
    ] autorelease];

    [sheet setBodyText:error];
    [sheet popupAlertAnimated:YES];
}

- (void) _setProgressTitle:(NSString *)title {
    [status_ setText:[title stringByAppendingString:@"..."]];
}

- (void) _setProgressPercent:(NSNumber *)percent {
    [progress_ setProgress:[percent floatValue]];
}

- (void) _addProgressOutput:(NSString *)output {
    [output_ setText:[NSString stringWithFormat:@"%@\n%@", [output_ text], output]];
    CGSize size = [output_ contentSize];
    CGRect rect = {{0, size.height}, {size.width, 0}};
    [output_ scrollRectToVisible:rect animated:YES];
}

@end
/* }}} */

/* Package Cell {{{ */
@interface PackageCell : UITableCell {
    UIImageView *icon_;
    UITextLabel *name_;
    UITextLabel *description_;
    UITextLabel *source_;
    //UIImageView *trusted_;
    UIImageView *badge_;
    UITextLabel *status_;
}

- (PackageCell *) init;
- (void) setPackage:(Package *)package;

- (void) _setSelected:(float)fraction;
- (void) setSelected:(BOOL)selected;
- (void) setSelected:(BOOL)selected withFade:(BOOL)fade;
- (void) _setSelectionFadeFraction:(float)fraction;

+ (int) heightForPackage:(Package *)package;

@end

@implementation PackageCell

- (void) dealloc {
    [icon_ release];
    [name_ release];
    [description_ release];
    [source_ release];
    [badge_ release];
    [status_ release];
    //[trusted_ release];
    [super dealloc];
}

- (PackageCell *) init {
    if ((self = [super init]) != nil) {
        GSFontRef bold = GSFontCreateWithName("Helvetica", kGSFontTraitBold, 20);
        GSFontRef large = GSFontCreateWithName("Helvetica", kGSFontTraitNone, 12);
        GSFontRef small = GSFontCreateWithName("Helvetica", kGSFontTraitNone, 14);

        icon_ = [[UIImageView alloc] initWithFrame:CGRectMake(10, 10, 30, 30)];

        name_ = [[UITextLabel alloc] initWithFrame:CGRectMake(48, 8, 240, 25)];
        [name_ setBackgroundColor:Clear_];
        [name_ setFont:bold];

        source_ = [[UITextLabel alloc] initWithFrame:CGRectMake(58, 28, 225, 20)];
        [source_ setBackgroundColor:Clear_];
        [source_ setFont:large];

        description_ = [[UITextLabel alloc] initWithFrame:CGRectMake(12, 46, 280, 20)];
        [description_ setBackgroundColor:Clear_];
        [description_ setFont:small];

        /*trusted_ = [[UIImageView alloc] initWithFrame:CGRectMake(30, 30, 16, 16)];
        [trusted_ setImage:[UIImage applicationImageNamed:@"trusted.png"]];*/

        badge_ = [[UIImageView alloc] initWithFrame:CGRectMake(17, 70, 16, 16)];

        status_ = [[UITextLabel alloc] initWithFrame:CGRectMake(48, 68, 280, 20)];
        [status_ setBackgroundColor:Clear_];
        [status_ setFont:small];

        [self addSubview:icon_];
        [self addSubview:name_];
        [self addSubview:description_];
        [self addSubview:source_];
        [self addSubview:badge_];
        [self addSubview:status_];

        CFRelease(small);
        CFRelease(large);
        CFRelease(bold);
    } return self;
}

- (void) setPackage:(Package *)package {
    Source *source = [package source];

    UIImage *image = nil;
    if (NSString *icon = [package icon])
        image = [UIImage imageAtPath:[icon substringFromIndex:6]];
    if (image == nil) if (NSString *icon = [source defaultIcon])
        image = [UIImage imageAtPath:[icon substringFromIndex:6]];
    if (image == nil)
        image = [UIImage applicationImageNamed:@"unknown.png"];
    [icon_ setImage:image];

    if (image != nil) {
        CGSize size = [image size];
        float scale = 30 / std::max(size.width, size.height);
        [icon_ zoomToScale:scale];
    }

    [icon_ setFrame:CGRectMake(10, 10, 30, 30)];

    [name_ setText:[package name]];
    [description_ setText:[package tagline]];

    NSString *label = nil;
    bool trusted = false;

    if (source != nil) {
        label = [source label];
        trusted = [source trusted];
    } else if ([[package id] isEqualToString:@"firmware"])
        label = @"Apple";

    if (label == nil)
        label = @"Unknown/Local";

    NSString *from = [NSString stringWithFormat:@"from %@", label];

    NSString *section = Simplify([package section]);
    if (section != nil && ![section isEqualToString:label])
        from = [from stringByAppendingString:[NSString stringWithFormat:@" (%@)", section]];

    [source_ setText:from];

    if (NSString *mode = [package mode]) {
        [badge_ setImage:[UIImage applicationImageNamed:
            [mode isEqualToString:@"Remove"] || [mode isEqualToString:@"Purge"] ? @"removing.png" : @"installing.png"
        ]];

        [status_ setText:[NSString stringWithFormat:@"Queued for %@", mode]];
        [status_ setColor:Blueish_];
    } else if ([package half]) {
        [badge_ setImage:[UIImage applicationImageNamed:@"damaged.png"]];
        [status_ setText:@"Package Damaged"];
        [status_ setColor:Red_];
    } else {
        [badge_ setImage:nil];
        [status_ setText:nil];
    }
}

- (void) _setSelected:(float)fraction {
    CGColor black(space_,
        Interpolate(0.0, 1.0, fraction),
        Interpolate(0.0, 1.0, fraction),
        Interpolate(0.0, 1.0, fraction),
    1.0);

    CGColor gray(space_,
        Interpolate(0.4, 1.0, fraction),
        Interpolate(0.4, 1.0, fraction),
        Interpolate(0.4, 1.0, fraction),
    1.0);

    [name_ setColor:black];
    [description_ setColor:gray];
    [source_ setColor:black];
}

- (void) setSelected:(BOOL)selected {
    [self _setSelected:(selected ? 1.0 : 0.0)];
    [super setSelected:selected];
}

- (void) setSelected:(BOOL)selected withFade:(BOOL)fade {
    if (!fade)
        [self _setSelected:(selected ? 1.0 : 0.0)];
    [super setSelected:selected withFade:fade];
}

- (void) _setSelectionFadeFraction:(float)fraction {
    [self _setSelected:fraction];
    [super _setSelectionFadeFraction:fraction];
}

+ (int) heightForPackage:(Package *)package {
    if ([package hasMode] || [package half])
        return 96;
    else
        return 73;
}

@end
/* }}} */
/* Section Cell {{{ */
@interface SectionCell : UITableCell {
    UITextLabel *name_;
    UITextLabel *count_;
}

- (id) init;
- (void) setSection:(Section *)section;

- (void) _setSelected:(float)fraction;
- (void) setSelected:(BOOL)selected;
- (void) setSelected:(BOOL)selected withFade:(BOOL)fade;
- (void) _setSelectionFadeFraction:(float)fraction;

@end

@implementation SectionCell

- (void) dealloc {
    [name_ release];
    [count_ release];
    [super dealloc];
}

- (id) init {
    if ((self = [super init]) != nil) {
        GSFontRef bold = GSFontCreateWithName("Helvetica", kGSFontTraitBold, 22);
        GSFontRef small = GSFontCreateWithName("Helvetica", kGSFontTraitBold, 12);

        name_ = [[UITextLabel alloc] initWithFrame:CGRectMake(48, 9, 250, 25)];
        [name_ setBackgroundColor:Clear_];
        [name_ setFont:bold];

        count_ = [[UITextLabel alloc] initWithFrame:CGRectMake(11, 7, 29, 32)];
        [count_ setCentersHorizontally:YES];
        [count_ setBackgroundColor:Clear_];
        [count_ setFont:small];
        [count_ setColor:White_];

        UIImageView *folder = [[[UIImageView alloc] initWithFrame:CGRectMake(8, 7, 32, 32)] autorelease];
        [folder setImage:[UIImage applicationImageNamed:@"folder.png"]];

        [self addSubview:folder];
        [self addSubview:name_];
        [self addSubview:count_];

        [self _setSelected:0];

        CFRelease(small);
        CFRelease(bold);
    } return self;
}

- (void) setSection:(Section *)section {
    if (section == nil) {
        [name_ setText:@"All Packages"];
        [count_ setText:nil];
    } else {
        NSString *name = [section name];
        [name_ setText:(name == nil ? @"(No Section)" : name)];
        [count_ setText:[NSString stringWithFormat:@"%d", [section count]]];
    }
}

- (void) _setSelected:(float)fraction {
    CGColor black(space_,
        Interpolate(0.0, 1.0, fraction),
        Interpolate(0.0, 1.0, fraction),
        Interpolate(0.0, 1.0, fraction),
    1.0);

    [name_ setColor:black];
}

- (void) setSelected:(BOOL)selected {
    [self _setSelected:(selected ? 1.0 : 0.0)];
    [super setSelected:selected];
}

- (void) setSelected:(BOOL)selected withFade:(BOOL)fade {
    if (!fade)
        [self _setSelected:(selected ? 1.0 : 0.0)];
    [super setSelected:selected withFade:fade];
}

- (void) _setSelectionFadeFraction:(float)fraction {
    [self _setSelected:fraction];
    [super _setSelectionFadeFraction:fraction];
}

@end
/* }}} */

/* File Table {{{ */
@interface FileTable : RVPage {
    _transient Database *database_;
    Package *package_;
    NSString *name_;
    NSMutableArray *files_;
    UITable *list_;
}

- (id) initWithBook:(RVBook *)book database:(Database *)database;
- (void) setPackage:(Package *)package;

@end

@implementation FileTable

- (void) dealloc {
    if (package_ != nil)
        [package_ release];
    if (name_ != nil)
        [name_ release];
    [files_ release];
    [list_ release];
    [super dealloc];
}

- (int) numberOfRowsInTable:(UITable *)table {
    return files_ == nil ? 0 : [files_ count];
}

- (float) table:(UITable *)table heightForRow:(int)row {
    return 24;
}

- (UITableCell *) table:(UITable *)table cellForRow:(int)row column:(UITableColumn *)col reusing:(UITableCell *)reusing {
    if (reusing == nil) {
        reusing = [[[UIImageAndTextTableCell alloc] init] autorelease];
        GSFontRef font = GSFontCreateWithName("Helvetica", kGSFontTraitNone, 16);
        [[(UIImageAndTextTableCell *)reusing titleTextLabel] setFont:font];
        CFRelease(font);
    }
    [(UIImageAndTextTableCell *)reusing setTitle:[files_ objectAtIndex:row]];
    return reusing;
}

- (BOOL) canSelectRow:(int)row {
    return NO;
}

- (id) initWithBook:(RVBook *)book database:(Database *)database {
    if ((self = [super initWithBook:book]) != nil) {
        database_ = database;

        files_ = [[NSMutableArray arrayWithCapacity:32] retain];

        list_ = [[UITable alloc] initWithFrame:[self bounds]];
        [self addSubview:list_];

        UITableColumn *column = [[[UITableColumn alloc]
            initWithTitle:@"Name"
            identifier:@"name"
            width:[self frame].size.width
        ] autorelease];

        [list_ setDataSource:self];
        [list_ setSeparatorStyle:1];
        [list_ addTableColumn:column];
        [list_ setDelegate:self];
        [list_ setReusesTableCells:YES];
    } return self;
}

- (void) setPackage:(Package *)package {
    if (package_ != nil) {
        [package_ autorelease];
        package_ = nil;
    }

    if (name_ != nil) {
        [name_ release];
        name_ = nil;
    }

    [files_ removeAllObjects];

    if (package != nil) {
        package_ = [package retain];
        name_ = [[package id] retain];

        NSString *path = [NSString stringWithFormat:@"/var/lib/dpkg/info/%@.list", name_];

        {
            std::ifstream fin([path UTF8String]);
            std::string line;
            while (std::getline(fin, line))
                [files_ addObject:[NSString stringWithUTF8String:line.c_str()]];
        }

        if ([files_ count] != 0) {
            if ([[files_ objectAtIndex:0] isEqualToString:@"/."])
                [files_ removeObjectAtIndex:0];
            [files_ sortUsingSelector:@selector(compareByPath:)];

            NSMutableArray *stack = [NSMutableArray arrayWithCapacity:8];
            [stack addObject:@"/"];

            for (int i(0), e([files_ count]); i != e; ++i) {
                NSString *file = [files_ objectAtIndex:i];
                while (![file hasPrefix:[stack lastObject]])
                    [stack removeLastObject];
                NSString *directory = [stack lastObject];
                [stack addObject:[file stringByAppendingString:@"/"]];
                [files_ replaceObjectAtIndex:i withObject:[NSString stringWithFormat:@"%*s%@",
                    ([stack count] - 2) * 3, "",
                    [file substringFromIndex:[directory length]]
                ]];
            }
        }
    }

    [list_ reloadData];
}

- (void) resetViewAnimated:(BOOL)animated {
    [list_ resetViewAnimated:animated];
}

- (void) reloadData {
    [self setPackage:[database_ packageWithName:name_]];
    [self reloadButtons];
}

- (NSString *) title {
    return @"Installed Files";
}

- (NSString *) backButtonTitle {
    return @"Files";
}

@end
/* }}} */
/* Package View {{{ */
@protocol PackageViewDelegate
- (void) performPackage:(Package *)package;
@end

@interface PackageView : RVPage {
    _transient Database *database_;
    UIPreferencesTable *table_;
    Package *package_;
    NSString *name_;
    UITextView *description_;
    NSMutableArray *buttons_;
}

- (id) initWithBook:(RVBook *)book database:(Database *)database;
- (void) setPackage:(Package *)package;

@end

@implementation PackageView

- (void) dealloc {
    [table_ setDataSource:nil];
    [table_ setDelegate:nil];

    if (package_ != nil)
        [package_ release];
    if (name_ != nil)
        [name_ release];
    if (description_ != nil)
        [description_ release];
    [table_ release];
    [buttons_ release];
    [super dealloc];
}

- (int) numberOfGroupsInPreferencesTable:(UIPreferencesTable *)table {
    int number = 2;
    if ([package_ installed] != nil)
        ++number;
    if ([package_ source] != nil)
        ++number;
    return number;
}

- (NSString *) preferencesTable:(UIPreferencesTable *)table titleForGroup:(int)group {
    if (group-- == 0)
        return nil;
    else if ([package_ installed] != nil && group-- == 0)
        return @"Installed Package";
    else if (group-- == 0)
        return @"Package Details";
    else if ([package_ source] != nil && group-- == 0)
        return @"Source Information";
    else _assert(false);
}

- (float) preferencesTable:(UIPreferencesTable *)table heightForRow:(int)row inGroup:(int)group withProposedHeight:(float)proposed {
    if (description_ == nil || group != 0 || row != 1)
        return proposed;
    else
        return [description_ visibleTextRect].size.height + TextViewOffset_;
}

- (int) preferencesTable:(UIPreferencesTable *)table numberOfRowsInGroup:(int)group {
    if (group-- == 0) {
        int number = 1;
        if ([package_ author] != nil)
            ++number;
        if (description_ != nil)
            ++number;
        if ([package_ website] != nil)
            ++number;
        if ([[package_ source] trusted])
            ++number;
        return number;
    } else if ([package_ installed] != nil && group-- == 0)
        return 2;
    else if (group-- == 0) {
        int number = 2;
        if ([package_ size] != 0)
            ++number;
        if ([package_ maintainer] != nil)
            ++number;
        if ([package_ relationships] != nil)
            ++number;
        return number;
    } else if ([package_ source] != nil && group-- == 0) {
        Source *source = [package_ source];
        NSString *description = [source description];
        int number = 1;
        if (description != nil && ![description isEqualToString:[source label]])
            ++number;
        if ([source origin] != nil)
            ++number;
        return number;
    } else _assert(false);
}

- (UIPreferencesTableCell *) preferencesTable:(UIPreferencesTable *)table cellForRow:(int)row inGroup:(int)group {
    UIPreferencesTableCell *cell = [[[UIPreferencesTableCell alloc] init] autorelease];
    [cell setShowSelection:NO];

    if (group-- == 0) {
        if (row-- == 0) {
            [cell setTitle:[package_ name]];
            [cell setValue:[package_ latest]];
        } else if ([package_ author] != nil && row-- == 0) {
            [cell setTitle:@"Author"];
            [cell setValue:[[package_ author] name]];
            [cell setShowDisclosure:YES];
            [cell setShowSelection:YES];
        } else if (description_ != nil && row-- == 0) {
            [cell addSubview:description_];
        } else if ([package_ website] != nil && row-- == 0) {
            [cell setTitle:@"More Information"];
            [cell setShowDisclosure:YES];
            [cell setShowSelection:YES];
        } else if ([[package_ source] trusted] && row-- == 0) {
            [cell setIcon:[UIImage applicationImageNamed:@"trusted.png"]];
            [cell setValue:@"This package has been signed."];
        } else _assert(false);
    } else if ([package_ installed] != nil && group-- == 0) {
        if (row-- == 0) {
            [cell setTitle:@"Version"];
            NSString *installed([package_ installed]);
            [cell setValue:(installed == nil ? @"n/a" : installed)];
        } else if (row-- == 0) {
            [cell setTitle:@"Filesystem Content"];
            [cell setShowDisclosure:YES];
            [cell setShowSelection:YES];
        } else _assert(false);
    } else if (group-- == 0) {
        if (row-- == 0) {
            [cell setTitle:@"Identifier"];
            [cell setValue:[package_ id]];
        } else if (row-- == 0) {
            [cell setTitle:@"Section"];
            NSString *section([package_ section]);
            [cell setValue:(section == nil ? @"n/a" : section)];
        } else if ([package_ size] != 0 && row-- == 0) {
            [cell setTitle:@"Expanded Size"];
            [cell setValue:SizeString([package_ size])];
        } else if ([package_ maintainer] != nil && row-- == 0) {
            [cell setTitle:@"Maintainer"];
            [cell setValue:[[package_ maintainer] name]];
            [cell setShowDisclosure:YES];
            [cell setShowSelection:YES];
        } else if ([package_ relationships] != nil && row-- == 0) {
            [cell setTitle:@"Package Relationships"];
            [cell setShowDisclosure:YES];
            [cell setShowSelection:YES];
        } else _assert(false);
    } else if ([package_ source] != nil && group-- == 0) {
        Source *source = [package_ source];
        NSString *description = [source description];

        if (row-- == 0) {
            NSString *label = [source label];
            if (label == nil)
                label = [source uri];
            [cell setTitle:label];
            [cell setValue:[source version]];
        } else if (description != nil && ![description isEqualToString:[source label]] && row-- == 0) {
            [cell setValue:description];
        } else if ([source origin] != nil && row-- == 0) {
            [cell setTitle:@"Origin"];
            [cell setValue:[source origin]];
        } else _assert(false);
    } else _assert(false);

    return cell;
}

- (BOOL) canSelectRow:(int)row {
    return YES;
}

// XXX: this is now unmaintainable
- (void) tableRowSelected:(NSNotification *)notification {
    int row = [table_ selectedRow];
    NSString *website = [package_ website];
    Address *author = [package_ author];
    BOOL trusted = [[package_ source] trusted];
    NSString *installed = [package_ installed];
    Address *maintainer = [package_ maintainer];

    if (maintainer != nil && row == 7
        + (author == nil ? 0 : 1)
        + (website == nil ? 0 : 1)
        + (trusted ? 1 : 0)
        + (installed == nil ? 0 : 3)
    ) {
        [delegate_ openURL:[NSURL URLWithString:[NSString stringWithFormat:@"mailto:%@?subject=%@",
            [maintainer email],
            [[NSString stringWithFormat:@"regarding apt package \"%@\"", [package_ name]] stringByAddingPercentEscapes]
        ]]];
    } else if (installed && row == 5
        + (author == nil ? 0 : 1)
        + (website == nil ? 0 : 1)
        + (trusted ? 1 : 0)
    ) {
        FileTable *files = [[[FileTable alloc] initWithBook:book_ database:database_] autorelease];
        [files setDelegate:delegate_];
        [files setPackage:package_];
        [book_ pushPage:files];
    } else if (author != nil && row == 2) {
        [delegate_ openURL:[NSURL URLWithString:[NSString stringWithFormat:@"mailto:%@?subject=%@",
            [author email],
            [[NSString stringWithFormat:@"regarding apt package \"%@\"", [package_ name]] stringByAddingPercentEscapes]
        ]]];
    } else if (website != nil && row == (author == nil ? 3 : 4)) {
        NSURL *url = [NSURL URLWithString:website];
        BrowserView *browser = [[[BrowserView alloc] initWithBook:book_ database:database_] autorelease];
        [browser setDelegate:delegate_];
        [book_ pushPage:browser];
        [browser loadURL:url];
    }
}

- (void) _clickButtonWithName:(NSString *)name {
    if ([name isEqualToString:@"Install"])
        [delegate_ installPackage:package_];
    else if ([name isEqualToString:@"Reinstall"])
        [delegate_ installPackage:package_];
    else if ([name isEqualToString:@"Remove"])
        [delegate_ removePackage:package_];
    else if ([name isEqualToString:@"Upgrade"])
        [delegate_ installPackage:package_];
    else _assert(false);
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    int count = [buttons_ count];
    _assert(count != 0);
    _assert(button <= count + 1);

    if (count != button - 1)
        [self _clickButtonWithName:[buttons_ objectAtIndex:(button - 1)]];

    [sheet dismiss];
}

- (void) _rightButtonClicked {
    int count = [buttons_ count];
    _assert(count != 0);

    if (count == 1)
        [self _clickButtonWithName:[buttons_ objectAtIndex:0]];
    else {
        NSMutableArray *buttons = [NSMutableArray arrayWithCapacity:(count + 1)];
        [buttons addObjectsFromArray:buttons_];
        [buttons addObject:@"Cancel"];

        [delegate_ slideUp:[[[UIAlertSheet alloc]
            initWithTitle:nil
            buttons:buttons
            defaultButtonIndex:2
            delegate:self
            context:@"manage"
        ] autorelease]];
    }
}

- (NSString *) rightButtonTitle {
    int count = [buttons_ count];
    return count == 0 ? nil : count != 1 ? @"Modify" : [buttons_ objectAtIndex:0];
}

- (NSString *) title {
    return @"Details";
}

- (id) initWithBook:(RVBook *)book database:(Database *)database {
    if ((self = [super initWithBook:book]) != nil) {
        database_ = database;

        table_ = [[UIPreferencesTable alloc] initWithFrame:[self bounds]];
        [self addSubview:table_];

        [table_ setDataSource:self];
        [table_ setDelegate:self];

        buttons_ = [[NSMutableArray alloc] initWithCapacity:4];
    } return self;
}

- (void) setPackage:(Package *)package {
    if (package_ != nil) {
        [package_ autorelease];
        package_ = nil;
    }

    if (name_ != nil) {
        [name_ release];
        name_ = nil;
    }

    if (description_ != nil) {
        [description_ release];
        description_ = nil;
    }

    [buttons_ removeAllObjects];

    if (package != nil) {
        package_ = [package retain];
        name_ = [[package id] retain];

        NSString *description([package description]);
        if (description == nil)
            description = [package tagline];
        if (description != nil) {
            description_ = [GetTextView(description, 12, true) retain];
            [description_ setTextColor:Black_];
        }

        [table_ reloadData];

        if ([package_ source] == nil);
        else if ([package_ installed] == nil)
            [buttons_ addObject:@"Install"];
        else if ([package_ upgradable])
            [buttons_ addObject:@"Upgrade"];
        else
            [buttons_ addObject:@"Reinstall"];
        if ([package_ installed] != nil)
            [buttons_ addObject:@"Remove"];
    }
}

- (void) resetViewAnimated:(BOOL)animated {
    [table_ resetViewAnimated:animated];
}

- (void) reloadData {
    [self setPackage:[database_ packageWithName:name_]];
    [self reloadButtons];
}

@end
/* }}} */
/* Package Table {{{ */
@interface PackageTable : RVPage {
    _transient Database *database_;
    NSString *title_;
    SEL filter_;
    id object_;
    NSMutableArray *packages_;
    NSMutableArray *sections_;
    UISectionList *list_;
}

- (id) initWithBook:(RVBook *)book database:(Database *)database title:(NSString *)title filter:(SEL)filter with:(id)object;

- (void) setDelegate:(id)delegate;
- (void) setObject:(id)object;

- (void) reloadData;
- (void) resetCursor;

- (UISectionList *) list;

- (void) setShouldHideHeaderInShortLists:(BOOL)hide;

@end

@implementation PackageTable

- (void) dealloc {
    [list_ setDataSource:nil];

    [title_ release];
    if (object_ != nil)
        [object_ release];
    [packages_ release];
    [sections_ release];
    [list_ release];
    [super dealloc];
}

- (int) numberOfSectionsInSectionList:(UISectionList *)list {
    return [sections_ count];
}

- (NSString *) sectionList:(UISectionList *)list titleForSection:(int)section {
    return [[sections_ objectAtIndex:section] name];
}

- (int) sectionList:(UISectionList *)list rowForSection:(int)section {
    return [[sections_ objectAtIndex:section] row];
}

- (int) numberOfRowsInTable:(UITable *)table {
    return [packages_ count];
}

- (float) table:(UITable *)table heightForRow:(int)row {
    return [PackageCell heightForPackage:[packages_ objectAtIndex:row]];
}

- (UITableCell *) table:(UITable *)table cellForRow:(int)row column:(UITableColumn *)col reusing:(UITableCell *)reusing {
    if (reusing == nil)
        reusing = [[[PackageCell alloc] init] autorelease];
    [(PackageCell *)reusing setPackage:[packages_ objectAtIndex:row]];
    return reusing;
}

- (BOOL) table:(UITable *)table showDisclosureForRow:(int)row {
    return NO;
}

- (void) tableRowSelected:(NSNotification *)notification {
    int row = [[notification object] selectedRow];
    if (row == INT_MAX)
        return;

    Package *package = [packages_ objectAtIndex:row];
    PackageView *view = [[[PackageView alloc] initWithBook:book_ database:database_] autorelease];
    [view setDelegate:delegate_];
    [view setPackage:package];
    [book_ pushPage:view];
}

- (id) initWithBook:(RVBook *)book database:(Database *)database title:(NSString *)title filter:(SEL)filter with:(id)object {
    if ((self = [super initWithBook:book]) != nil) {
        database_ = database;
        title_ = [title retain];
        filter_ = filter;
        object_ = object == nil ? nil : [object retain];

        packages_ = [[NSMutableArray arrayWithCapacity:16] retain];
        sections_ = [[NSMutableArray arrayWithCapacity:16] retain];

        list_ = [[UISectionList alloc] initWithFrame:[self bounds] showSectionIndex:YES];
        [list_ setDataSource:self];

        UITableColumn *column = [[[UITableColumn alloc]
            initWithTitle:@"Name"
            identifier:@"name"
            width:[self frame].size.width
        ] autorelease];

        UITable *table = [list_ table];
        [table setSeparatorStyle:1];
        [table addTableColumn:column];
        [table setDelegate:self];
        [table setReusesTableCells:YES];

        [self addSubview:list_];
        [self reloadData];
    } return self;
}

- (void) setDelegate:(id)delegate {
    delegate_ = delegate;
}

- (void) setObject:(id)object {
    if (object_ != nil)
        [object_ release];
    if (object == nil)
        object_ = nil;
    else
        object_ = [object retain];
}

- (void) reloadData {
    NSArray *packages = [database_ packages];

    [packages_ removeAllObjects];
    [sections_ removeAllObjects];

    for (size_t i(0); i != [packages count]; ++i) {
        Package *package([packages objectAtIndex:i]);
        if ([[package performSelector:filter_ withObject:object_] boolValue])
            [packages_ addObject:package];
    }

    Section *section = nil;

    for (size_t offset(0); offset != [packages_ count]; ++offset) {
        Package *package = [packages_ objectAtIndex:offset];
        NSString *name = [package index];

        if (section == nil || ![[section name] isEqualToString:name]) {
            section = [[[Section alloc] initWithName:name row:offset] autorelease];
            [sections_ addObject:section];
        }

        [section addToCount];
    }

    [list_ reloadData];
}

- (NSString *) title {
    return title_;
}

- (void) resetViewAnimated:(BOOL)animated {
    [list_ resetViewAnimated:animated];
}

- (void) resetCursor {
    [[list_ table] scrollPointVisibleAtTopLeft:CGPointMake(0, 0) animated:NO];
}

- (UISectionList *) list {
    return list_;
}

- (void) setShouldHideHeaderInShortLists:(BOOL)hide {
    [list_ setShouldHideHeaderInShortLists:hide];
}

@end
/* }}} */

/* Browser Implementation {{{ */
@implementation BrowserView

- (void) dealloc {
    WebView *webview = [webview_ webView];
    [webview setFrameLoadDelegate:nil];
    [webview setResourceLoadDelegate:nil];
    [webview setUIDelegate:nil];

    [scroller_ setDelegate:nil];
    [webview_ setDelegate:nil];

    [scroller_ release];
    [webview_ release];
    [urls_ release];
    [indicator_ release];
    if (title_ != nil)
        [title_ release];
    [super dealloc];
}

- (void) loadURL:(NSURL *)url cachePolicy:(NSURLRequestCachePolicy)policy {
    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:url
        cachePolicy:policy
        timeoutInterval:30.0
    ];

    [request addValue:[NSString stringWithUTF8String:Firmware_] forHTTPHeaderField:@"X-Firmware"];
    [request addValue:[NSString stringWithUTF8String:Machine_] forHTTPHeaderField:@"X-Machine"];
    [request addValue:[NSString stringWithUTF8String:SerialNumber_] forHTTPHeaderField:@"X-Serial-Number"];

    [self loadRequest:request];
}


- (void) loadURL:(NSURL *)url {
    [self loadURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy];
}

// XXX: this needs to add the headers
- (NSURLRequest *) _addHeadersToRequest:(NSURLRequest *)request {
    return request;
}

- (void) loadRequest:(NSURLRequest *)request {
    [webview_ loadRequest:request];
}

- (void) reloadURL {
    NSURL *url = [[[urls_ lastObject] retain] autorelease];
    [urls_ removeLastObject];
    [self loadURL:url cachePolicy:NSURLRequestReloadIgnoringCacheData];
}

- (WebView *) webView {
    return [webview_ webView];
}

- (void) view:(UIView *)sender didSetFrame:(CGRect)frame {
    [scroller_ setContentSize:frame.size];
}

- (void) view:(UIView *)sender didSetFrame:(CGRect)frame oldFrame:(CGRect)old {
    [self view:sender didSetFrame:frame];
}

- (NSURLRequest *) webView:(WebView *)sender resource:(id)identifier willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse fromDataSource:(WebDataSource *)dataSource {
    return [self _addHeadersToRequest:request];
}

- (WebView *) webView:(WebView *)sender createWebViewWithRequest:(NSURLRequest *)request {
    if ([[[request URL] scheme] isEqualToString:@"apptapp"])
        return nil;
    [self setBackButtonTitle:title_];
    BrowserView *browser = [[[BrowserView alloc] initWithBook:book_ database:database_] autorelease];
    [browser setDelegate:delegate_];
    [book_ pushPage:browser];
    [browser loadRequest:[self _addHeadersToRequest:request]];
    return [browser webView];
}

- (void) webView:(WebView *)sender willClickElement:(id)element {
    if (![element respondsToSelector:@selector(href)])
        return;
    NSString *href = [element href];
    if (href == nil)
        return;
    if ([href hasPrefix:@"apptapp://package/"]) {
        NSString *name = [href substringFromIndex:18];
        Package *package = [database_ packageWithName:name];
        if (package == nil) {
            UIAlertSheet *sheet = [[[UIAlertSheet alloc]
                initWithTitle:@"Cannot Locate Package"
                buttons:[NSArray arrayWithObjects:@"Close", nil]
                defaultButtonIndex:0
                delegate:self
                context:@"missing"
            ] autorelease];

            [sheet setBodyText:[NSString stringWithFormat:
                @"The package %@ cannot be found in your current sources. I might recommend installing more sources."
            , name]];

            [sheet popupAlertAnimated:YES];
        } else {
            [self setBackButtonTitle:title_];
            PackageView *view = [[[PackageView alloc] initWithBook:book_ database:database_] autorelease];
            [view setDelegate:delegate_];
            [view setPackage:package];
            [book_ pushPage:view];
        }
    }
}

- (void) webView:(WebView *)sender didReceiveTitle:(NSString *)title forFrame:(WebFrame *)frame {
    title_ = [title retain];
    [self setTitle:title];
}

- (void) webView:(WebView *)sender didStartProvisionalLoadForFrame:(WebFrame *)frame {
    if ([frame parentFrame] != nil)
        return;

    reloading_ = false;
    loading_ = true;
    [indicator_ startAnimation];
    [self reloadButtons];

    if (title_ != nil) {
        [title_ release];
        title_ = nil;
    }

    [self setTitle:@"Loading..."];

    WebView *webview = [webview_ webView];
    NSString *href = [webview mainFrameURL];
    [urls_ addObject:[NSURL URLWithString:href]];

    CGRect webrect = [scroller_ frame];
    webrect.size.height = 0;
    [webview_ setFrame:webrect];
}

- (void) _finishLoading {
    if (!reloading_) {
        loading_ = false;
        [indicator_ stopAnimation];
        [self reloadButtons];
    }
}

- (void) webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame {
    if ([frame parentFrame] != nil)
        return;
    [self _finishLoading];
}

- (void) webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
    if ([frame parentFrame] != nil)
        return;
    [self setTitle:[error localizedDescription]];
    [self _finishLoading];
}

- (id) initWithBook:(RVBook *)book database:(Database *)database {
    if ((self = [super initWithBook:book]) != nil) {
        database_ = database;
        loading_ = false;

        struct CGRect bounds = [self bounds];

        UIImageView *pinstripe = [[[UIImageView alloc] initWithFrame:bounds] autorelease];
        [pinstripe setImage:[UIImage applicationImageNamed:@"pinstripe.png"]];
        [self addSubview:pinstripe];

        scroller_ = [[UIScroller alloc] initWithFrame:bounds];
        [self addSubview:scroller_];

        [scroller_ setScrollingEnabled:YES];
        [scroller_ setAdjustForContentSizeChange:YES];
        [scroller_ setClipsSubviews:YES];
        [scroller_ setAllowsRubberBanding:YES];
        [scroller_ setScrollDecelerationFactor:0.99];
        [scroller_ setDelegate:self];

        CGRect webrect = [scroller_ bounds];
        webrect.size.height = 0;

        webview_ = [[UIWebView alloc] initWithFrame:webrect];
        [scroller_ addSubview:webview_];

        [webview_ setTilingEnabled:YES];
        [webview_ setTileSize:CGSizeMake(webrect.size.width, 500)];
        [webview_ setAutoresizes:YES];
        [webview_ setDelegate:self];
        //[webview_ setEnabledGestures:2];

        CGSize indsize = [UIProgressIndicator defaultSizeForStyle:0];
        indicator_ = [[UIProgressIndicator alloc] initWithFrame:CGRectMake(281, 42, indsize.width, indsize.height)];
        [indicator_ setStyle:0];

        Package *package([database_ packageWithName:@"cydia"]);
        NSString *application = package == nil ? @"Cydia" : [NSString
            stringWithFormat:@"Cydia/%@",
            [package installed]
        ];

        WebView *webview = [webview_ webView];
        [webview setApplicationNameForUserAgent:application];
        [webview setFrameLoadDelegate:self];
        [webview setResourceLoadDelegate:self];
        [webview setUIDelegate:self];

        urls_ = [[NSMutableArray alloc] initWithCapacity:16];
    } return self;
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    [sheet dismiss];
}

- (void) _leftButtonClicked {
    UIAlertSheet *sheet = [[[UIAlertSheet alloc]
        initWithTitle:@"About Cydia Packager"
        buttons:[NSArray arrayWithObjects:@"Close", nil]
        defaultButtonIndex:0
        delegate:self
        context:@"about"
    ] autorelease];

    [sheet setBodyText:
        @"Copyright (C) 2008\n"
        "Jay Freeman (saurik)\n"
        "saurik@saurik.com\n"
        "http://www.saurik.com/\n"
        "\n"
        "The Okori Group\n"
        "http://www.theokorigroup.com/\n"
        "\n"
        "College of Creative Studies,\n"
        "University of California,\n"
        "Santa Barbara\n"
        "http://www.ccs.ucsb.edu/"
    ];

    [sheet popupAlertAnimated:YES];
}

- (void) _rightButtonClicked {
    reloading_ = true;
    [self reloadURL];
}

- (NSString *) leftButtonTitle {
    return @"About";
}

- (NSString *) rightButtonTitle {
    return loading_ ? @"" : @"Reload";
}

- (NSString *) title {
    return nil;
}

- (NSString *) backButtonTitle {
    return @"Browser";
}

- (void) setPageActive:(BOOL)active {
    if (active)
        [book_ addSubview:indicator_];
    else
        [indicator_ removeFromSuperview];
}

- (void) resetViewAnimated:(BOOL)animated {
}

@end
/* }}} */

@interface CYBook : RVBook <
    ProgressDelegate
> {
    _transient Database *database_;
    UIView *overlay_;
    UIProgressIndicator *indicator_;
    UITextLabel *prompt_;
    UIProgressBar *progress_;
    bool updating_;
}

- (id) initWithFrame:(CGRect)frame database:(Database *)database;
- (void) update;
- (BOOL) updating;

@end

/* Install View {{{ */
@interface InstallView : RVPage {
    _transient Database *database_;
    NSMutableArray *packages_;
    NSMutableArray *sections_;
    UITable *list_;
    UIView *accessory_;
}

- (id) initWithBook:(RVBook *)book database:(Database *)database;
- (void) reloadData;

@end

@implementation InstallView

- (void) dealloc {
    [list_ setDataSource:nil];
    [list_ setDelegate:nil];

    [packages_ release];
    [sections_ release];
    [list_ release];
    [accessory_ release];
    [super dealloc];
}

- (int) numberOfRowsInTable:(UITable *)table {
    return [sections_ count] + 1;
}

- (float) table:(UITable *)table heightForRow:(int)row {
    return 45;
}

- (UITableCell *) table:(UITable *)table cellForRow:(int)row column:(UITableColumn *)col reusing:(UITableCell *)reusing {
    if (reusing == nil)
        reusing = [[[SectionCell alloc] init] autorelease];
    [(SectionCell *)reusing setSection:(row == 0 ? nil : [sections_ objectAtIndex:(row - 1)])];
    return reusing;
}

- (BOOL) table:(UITable *)table showDisclosureForRow:(int)row {
    return YES;
}

- (void) tableRowSelected:(NSNotification *)notification {
    int row = [[notification object] selectedRow];
    if (row == INT_MAX)
        return;

    Section *section;
    NSString *name;
    NSString *title;

    if (row == 0) {
        section = nil;
        name = nil;
        title = @"All Packages";
    } else {
        section = [sections_ objectAtIndex:(row - 1)];
        name = [section name];

        if (name != nil)
            title = name;
        else {
            name = @"";
            title = @"(No Section)";
        }
    }

    PackageTable *table = [[[PackageTable alloc]
        initWithBook:book_
        database:database_
        title:title
        filter:@selector(isUninstalledInSection:)
        with:name
    ] autorelease];

    [table setDelegate:delegate_];

    [book_ pushPage:table];
}

- (id) initWithBook:(RVBook *)book database:(Database *)database {
    if ((self = [super initWithBook:book]) != nil) {
        database_ = database;

        packages_ = [[NSMutableArray arrayWithCapacity:16] retain];
        sections_ = [[NSMutableArray arrayWithCapacity:16] retain];

        list_ = [[UITable alloc] initWithFrame:[self bounds]];
        [self addSubview:list_];

        UITableColumn *column = [[[UITableColumn alloc]
            initWithTitle:@"Name"
            identifier:@"name"
            width:[self frame].size.width
        ] autorelease];

        [list_ setDataSource:self];
        [list_ setSeparatorStyle:1];
        [list_ addTableColumn:column];
        [list_ setDelegate:self];
        [list_ setReusesTableCells:YES];

        [self reloadData];
    } return self;
}

- (void) reloadData {
    NSArray *packages = [database_ packages];

    [packages_ removeAllObjects];
    [sections_ removeAllObjects];

    for (size_t i(0); i != [packages count]; ++i) {
        Package *package([packages objectAtIndex:i]);
        if ([package valid] && [package installed] == nil)
            [packages_ addObject:package];
    }

    [packages_ sortUsingSelector:@selector(compareBySection:)];

    Section *section = nil;
    for (size_t offset = 0, count = [packages_ count]; offset != count; ++offset) {
        Package *package = [packages_ objectAtIndex:offset];
        NSString *name = [package section];

        if (section == nil || name != nil && ![[section name] isEqualToString:name]) {
            section = [[[Section alloc] initWithName:name row:offset] autorelease];
            [sections_ addObject:section];
        }

        [section addToCount];
    }

    [list_ reloadData];
}

- (void) resetViewAnimated:(BOOL)animated {
    [list_ resetViewAnimated:animated];
}

- (NSString *) title {
    return @"Install";
}

- (NSString *) backButtonTitle {
    return @"Sections";
}

- (UIView *) accessoryView {
    return accessory_;
}

@end
/* }}} */
/* Changes View {{{ */
@interface ChangesView : RVPage {
    _transient Database *database_;
    NSMutableArray *packages_;
    NSMutableArray *sections_;
    UISectionList *list_;
    unsigned upgrades_;
}

- (id) initWithBook:(RVBook *)book database:(Database *)database;
- (void) reloadData;

@end

@implementation ChangesView

- (void) dealloc {
    [[list_ table] setDelegate:nil];
    [list_ setDataSource:nil];

    [packages_ release];
    [sections_ release];
    [list_ release];
    [super dealloc];
}

- (int) numberOfSectionsInSectionList:(UISectionList *)list {
    return [sections_ count];
}

- (NSString *) sectionList:(UISectionList *)list titleForSection:(int)section {
    return [[sections_ objectAtIndex:section] name];
}

- (int) sectionList:(UISectionList *)list rowForSection:(int)section {
    return [[sections_ objectAtIndex:section] row];
}

- (int) numberOfRowsInTable:(UITable *)table {
    return [packages_ count];
}

- (float) table:(UITable *)table heightForRow:(int)row {
    return [PackageCell heightForPackage:[packages_ objectAtIndex:row]];
}

- (UITableCell *) table:(UITable *)table cellForRow:(int)row column:(UITableColumn *)col reusing:(UITableCell *)reusing {
    if (reusing == nil)
        reusing = [[[PackageCell alloc] init] autorelease];
    [(PackageCell *)reusing setPackage:[packages_ objectAtIndex:row]];
    return reusing;
}

- (BOOL) table:(UITable *)table showDisclosureForRow:(int)row {
    return NO;
}

- (void) tableRowSelected:(NSNotification *)notification {
    int row = [[notification object] selectedRow];
    if (row == INT_MAX)
        return;
    Package *package = [packages_ objectAtIndex:row];
    PackageView *view = [[[PackageView alloc] initWithBook:book_ database:database_] autorelease];
    [view setDelegate:delegate_];
    [view setPackage:package];
    [book_ pushPage:view];
}

- (void) _leftButtonClicked {
    [(CYBook *)book_ update];
    [self reloadButtons];
}

- (void) _rightButtonClicked {
    [delegate_ distUpgrade];
}

- (id) initWithBook:(RVBook *)book database:(Database *)database {
    if ((self = [super initWithBook:book]) != nil) {
        database_ = database;

        packages_ = [[NSMutableArray arrayWithCapacity:16] retain];
        sections_ = [[NSMutableArray arrayWithCapacity:16] retain];

        list_ = [[UISectionList alloc] initWithFrame:[self bounds] showSectionIndex:NO];
        [self addSubview:list_];

        [list_ setShouldHideHeaderInShortLists:NO];
        [list_ setDataSource:self];
        //[list_ setSectionListStyle:1];

        UITableColumn *column = [[[UITableColumn alloc]
            initWithTitle:@"Name"
            identifier:@"name"
            width:[self frame].size.width
        ] autorelease];

        UITable *table = [list_ table];
        [table setSeparatorStyle:1];
        [table addTableColumn:column];
        [table setDelegate:self];
        [table setReusesTableCells:YES];

        [self reloadData];
    } return self;
}

- (void) reloadData {
    NSArray *packages = [database_ packages];

    [packages_ removeAllObjects];
    [sections_ removeAllObjects];

    for (size_t i(0); i != [packages count]; ++i) {
        Package *package([packages objectAtIndex:i]);
        if ([package installed] == nil && [package valid] || [package upgradable])
            [packages_ addObject:package];
    }

    [packages_ sortUsingSelector:@selector(compareForChanges:)];

    Section *upgradable = [[[Section alloc] initWithName:@"Available Upgrades" row:0] autorelease];
    Section *section = nil;

    upgrades_ = 0;
    bool unseens = false;

    CFLocaleRef locale = CFLocaleCopyCurrent();
    CFDateFormatterRef formatter = CFDateFormatterCreate(NULL, locale, kCFDateFormatterMediumStyle, kCFDateFormatterMediumStyle);

    for (size_t offset = 0, count = [packages_ count]; offset != count; ++offset) {
        Package *package = [packages_ objectAtIndex:offset];

        if ([package upgradable]) {
            ++upgrades_;
            [upgradable addToCount];
        } else {
            unseens = true;
            NSDate *seen = [package seen];

            NSString *name;

            if (seen == nil)
                name = [@"n/a ?" retain];
            else {
                name = (NSString *) CFDateFormatterCreateStringWithDate(NULL, formatter, (CFDateRef) seen);
            }

            if (section == nil || ![[section name] isEqualToString:name]) {
                section = [[[Section alloc] initWithName:name row:offset] autorelease];
                [sections_ addObject:section];
            }

            [name release];
            [section addToCount];
        }
    }

    CFRelease(formatter);
    CFRelease(locale);

    if (unseens) {
        Section *last = [sections_ lastObject];
        size_t count = [last count];
        [packages_ removeObjectsInRange:NSMakeRange([packages_ count] - count, count)];
        [sections_ removeLastObject];
    }

    if (upgrades_ != 0)
        [sections_ insertObject:upgradable atIndex:0];

    [list_ reloadData];
    [self reloadButtons];
}

- (void) resetViewAnimated:(BOOL)animated {
    [list_ resetViewAnimated:animated];
}

- (NSString *) leftButtonTitle {
    return [(CYBook *)book_ updating] ? nil : @"Refresh";
}

- (NSString *) rightButtonTitle {
    return upgrades_ == 0 ? nil : [NSString stringWithFormat:@"Upgrade All (%u)", upgrades_];
}

- (NSString *) title {
    return @"Changes";
}

@end
/* }}} */
/* Manage View {{{ */
@interface ManageView : PackageTable {
}

- (id) initWithBook:(RVBook *)book database:(Database *)database;

@end

@implementation ManageView

- (id) initWithBook:(RVBook *)book database:(Database *)database {
    if ((self = [super
        initWithBook:book
        database:database
        title:nil
        filter:@selector(isInstalledInSection:)
        with:nil
    ]) != nil) {
    } return self;
}

- (NSString *) title {
    return @"Installed Packages";
}

- (NSString *) backButtonTitle {
    return @"All Packages";
}

@end
/* }}} */
/* Search View {{{ */
@protocol SearchViewDelegate
- (void) showKeyboard:(BOOL)show;
@end

@interface SearchView : RVPage {
    UIView *accessory_;
    UISearchField *field_;
    UITransitionView *transition_;
    PackageTable *table_;
    UIPreferencesTable *advanced_;
    UIView *dimmed_;
    bool flipped_;
    bool reload_;
}

- (id) initWithBook:(RVBook *)book database:(Database *)database;
- (void) reloadData;

@end

@implementation SearchView

- (void) dealloc {
#ifndef __OBJC2__
    [[field_ textTraits] setEditingDelegate:nil];
#endif
    [field_ setDelegate:nil];

    [accessory_ release];
    [field_ release];
    [transition_ release];
    [table_ release];
    [advanced_ release];
    [dimmed_ release];
    [super dealloc];
}

- (int) numberOfGroupsInPreferencesTable:(UIPreferencesTable *)table {
    return 1;
}

- (NSString *) preferencesTable:(UIPreferencesTable *)table titleForGroup:(int)group {
    switch (group) {
        case 0: return @"Advanced Search (Coming Soon!)";

        default: _assert(false);
    }
}

- (int) preferencesTable:(UIPreferencesTable *)table numberOfRowsInGroup:(int)group {
    switch (group) {
        case 0: return 0;

        default: _assert(false);
    }
}

- (void) _showKeyboard:(BOOL)show {
    CGSize keysize = [UIKeyboard defaultSize];
    CGRect keydown = [book_ pageBounds];
    CGRect keyup = keydown;
    keyup.size.height -= keysize.height - ButtonBarHeight_;

    float delay = KeyboardTime_ * ButtonBarHeight_ / keysize.height;

    UIFrameAnimation *animation = [[[UIFrameAnimation alloc] initWithTarget:[table_ list]] autorelease];
    [animation setSignificantRectFields:8];

    if (show) {
        [animation setStartFrame:keydown];
        [animation setEndFrame:keyup];
    } else {
        [animation setStartFrame:keyup];
        [animation setEndFrame:keydown];
    }

    UIAnimator *animator = [UIAnimator sharedAnimator];

    [animator
        addAnimations:[NSArray arrayWithObjects:animation, nil]
        withDuration:(KeyboardTime_ - delay)
        start:!show
    ];

    if (show)
        [animator performSelector:@selector(startAnimation:) withObject:animation afterDelay:delay];

    [delegate_ showKeyboard:show];
}

- (void) textFieldDidBecomeFirstResponder:(UITextField *)field {
    [self _showKeyboard:YES];
}

- (void) textFieldDidResignFirstResponder:(UITextField *)field {
    [self _showKeyboard:NO];
}

- (void) keyboardInputChanged:(UIFieldEditor *)editor {
    if (reload_) {
        NSString *text([field_ text]);
        [field_ setClearButtonStyle:(text == nil || [text length] == 0 ? 0 : 2)];
        [self reloadData];
        reload_ = false;
    }
}

- (void) textFieldClearButtonPressed:(UITextField *)field {
    reload_ = true;
}

- (void) keyboardInputShouldDelete:(id)input {
    reload_ = true;
}

- (BOOL) keyboardInput:(id)input shouldInsertText:(NSString *)text isMarkedText:(int)marked {
    if ([text length] != 1 || [text characterAtIndex:0] != '\n') {
        reload_ = true;
        return YES;
    } else {
        [field_ resignFirstResponder];
        return NO;
    }
}

- (id) initWithBook:(RVBook *)book database:(Database *)database {
    if ((self = [super initWithBook:book]) != nil) {
        CGRect pageBounds = [book_ pageBounds];

        /*UIImageView *pinstripe = [[[UIImageView alloc] initWithFrame:pageBounds] autorelease];
        [pinstripe setImage:[UIImage applicationImageNamed:@"pinstripe.png"]];
        [self addSubview:pinstripe];*/

        transition_ = [[UITransitionView alloc] initWithFrame:pageBounds];
        [self addSubview:transition_];

        advanced_ = [[UIPreferencesTable alloc] initWithFrame:pageBounds];

        [advanced_ setReusesTableCells:YES];
        [advanced_ setDataSource:self];
        [advanced_ reloadData];

        dimmed_ = [[UIView alloc] initWithFrame:pageBounds];
        CGColor dimmed(space_, 0, 0, 0, 0.5);
        [dimmed_ setBackgroundColor:dimmed];

        table_ = [[PackageTable alloc]
            initWithBook:book
            database:database
            title:nil
            filter:@selector(isSearchedForBy:)
            with:nil
        ];

        [table_ setShouldHideHeaderInShortLists:NO];
        [transition_ transition:0 toView:table_];

        CGRect cnfrect = {{1, 38}, {17, 18}};

        CGRect area;
        area.origin.x = cnfrect.size.width + 15;
        area.origin.y = 30;
        area.size.width = [self bounds].size.width - area.origin.x - 18;
        area.size.height = [UISearchField defaultHeight];

        field_ = [[UISearchField alloc] initWithFrame:area];

        GSFontRef font = GSFontCreateWithName("Helvetica", kGSFontTraitNone, 16);
        [field_ setFont:font];
        CFRelease(font);

        [field_ setPlaceholder:@"Package Names & Descriptions"];
        [field_ setPaddingTop:5];
        [field_ setDelegate:self];

#ifndef __OBJC2__
        UITextTraits *traits = [field_ textTraits];
        [traits setEditingDelegate:self];
        [traits setReturnKeyType:6];
        [traits setAutoCapsType:0];
        [traits setAutoCorrectionType:1];
#endif

        UIPushButton *configure = [[[UIPushButton alloc] initWithFrame:cnfrect] autorelease];
        [configure setShowPressFeedback:YES];
        [configure setImage:[UIImage applicationImageNamed:@"advanced.png"]];
        [configure addTarget:self action:@selector(configurePushed) forEvents:1];

        accessory_ = [[UIView alloc] initWithFrame:CGRectMake(0, 6, cnfrect.size.width + area.size.width + 6 * 3, area.size.height + 30)];
        [accessory_ addSubview:field_];
        [accessory_ addSubview:configure];
    } return self;
}

- (void) flipPage {
    LKAnimation *animation = [LKTransition animation];
    [animation setType:@"oglFlip"];
    [animation setTimingFunction:[LKTimingFunction functionWithName:@"easeInEaseOut"]];
    [animation setFillMode:@"extended"];
    [animation setTransitionFlags:3];
    [animation setDuration:10];
    [animation setSpeed:0.35];
    [animation setSubtype:(flipped_ ? @"fromLeft" : @"fromRight")];
    [[transition_ _layer] addAnimation:animation forKey:0];
    [transition_ transition:0 toView:(flipped_ ? (UIView *) table_ : (UIView *) advanced_)];
    flipped_ = !flipped_;
}

- (void) configurePushed {
    [field_ resignFirstResponder];
    [self flipPage];
}

- (void) resetViewAnimated:(BOOL)animated {
    if (flipped_)
        [self flipPage];
    [table_ resetViewAnimated:animated];
}

- (void) reloadData {
    if (flipped_)
        [self flipPage];
    [table_ setObject:[field_ text]];
    [table_ reloadData];
    [table_ resetCursor];
}

- (UIView *) accessoryView {
    return accessory_;
}

- (NSString *) title {
    return nil;
}

- (NSString *) backButtonTitle {
    return @"Search";
}

- (void) setDelegate:(id)delegate {
    [table_ setDelegate:delegate];
    [super setDelegate:delegate];
}

@end
/* }}} */

@implementation CYBook

- (void) dealloc {
    [overlay_ release];
    [indicator_ release];
    [prompt_ release];
    [progress_ release];
    [super dealloc];
}

- (NSString *) getTitleForPage:(RVPage *)page {
    return Simplify([super getTitleForPage:page]);
}

- (BOOL) updating {
    return updating_;
}

- (void) update {
    [navbar_ setPrompt:@""];
    [navbar_ addSubview:overlay_];
    [indicator_ startAnimation];
    [prompt_ setText:@"Updating Database..."];
    [progress_ setProgress:0];

    updating_ = true;

    [NSThread
        detachNewThreadSelector:@selector(_update)
        toTarget:self
        withObject:nil
    ];
}

- (void) _update_ {
    updating_ = false;

    [overlay_ removeFromSuperview];
    [indicator_ stopAnimation];
    [delegate_ reloadData];

    [self setPrompt:[NSString stringWithFormat:@"Last Updated: %@", GetLastUpdate()]];
}

- (id) initWithFrame:(CGRect)frame database:(Database *)database {
    if ((self = [super initWithFrame:frame]) != nil) {
        database_ = database;

        if (Advanced_)
            [navbar_ setBarStyle:1];

        CGRect ovrrect = [navbar_ bounds];
        ovrrect.size.height = [UINavigationBar defaultSizeWithPrompt].height - [UINavigationBar defaultSize].height;

        overlay_ = [[UIView alloc] initWithFrame:ovrrect];

        CGSize indsize = [UIProgressIndicator defaultSizeForStyle:2];
        unsigned indoffset = (ovrrect.size.height - indsize.height) / 2;
        CGRect indrect = {{indoffset, indoffset}, indsize};

        indicator_ = [[UIProgressIndicator alloc] initWithFrame:indrect];
        [indicator_ setStyle:(Advanced_ ? 2 : 3)];
        [overlay_ addSubview:indicator_];

        CGSize prmsize = {200, indsize.width};

        CGRect prmrect = {{
            indoffset * 2 + indsize.width,
            (ovrrect.size.height - prmsize.height) / 2
        }, prmsize};

        GSFontRef font = GSFontCreateWithName("Helvetica", kGSFontTraitNone, 12);

        prompt_ = [[UITextLabel alloc] initWithFrame:prmrect];

        [prompt_ setColor:(Advanced_ ? White_ : Blueish_)];
        [prompt_ setBackgroundColor:Clear_];
        [prompt_ setFont:font];

        CFRelease(font);

        [overlay_ addSubview:prompt_];

        CGSize prgsize = {75, 100};

        CGRect prgrect = {{
            ovrrect.size.width - prgsize.width - 10,
            (ovrrect.size.height - prgsize.height) / 2
        } , prgsize};

        progress_ = [[UIProgressBar alloc] initWithFrame:prgrect];
        [progress_ setStyle:0];
        [overlay_ addSubview:progress_];
    } return self;
}

- (void) _update {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    Status status;
    status.setDelegate(self);

    [database_ updateWithStatus:status];

    [self
        performSelectorOnMainThread:@selector(_update_)
        withObject:nil
        waitUntilDone:NO
    ];

    [pool release];
}

- (void) setProgressError:(NSString *)error {
    [self
        performSelectorOnMainThread:@selector(_setProgressError:)
        withObject:error
        waitUntilDone:YES
    ];
}

- (void) setProgressTitle:(NSString *)title {
    [self
        performSelectorOnMainThread:@selector(_setProgressTitle:)
        withObject:title
        waitUntilDone:YES
    ];
}

- (void) setProgressPercent:(float)percent {
}

- (void) addProgressOutput:(NSString *)output {
    [self
        performSelectorOnMainThread:@selector(_addProgressOutput:)
        withObject:output
        waitUntilDone:YES
    ];
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    [sheet dismiss];
}

- (void) _setProgressError:(NSString *)error {
    [prompt_ setText:[NSString stringWithFormat:@"Error: %@", error]];
}

- (void) _setProgressTitle:(NSString *)title {
    [prompt_ setText:[title stringByAppendingString:@"..."]];
}

- (void) _addProgressOutput:(NSString *)output {
}

@end

@interface Cydia : UIApplication <
    ConfirmationViewDelegate,
    ProgressViewDelegate,
    SearchViewDelegate,
    CydiaDelegate
> {
    UIWindow *window_;

    UIView *underlay_;
    UIView *overlay_;
    CYBook *book_;
    UIButtonBar *buttonbar_;

    ConfirmationView *confirm_;

    NSMutableArray *essential_;
    NSMutableArray *broken_;

    Database *database_;
    ProgressView *progress_;

    unsigned tag_;

    UIKeyboard *keyboard_;

    InstallView *install_;
    ChangesView *changes_;
    ManageView *manage_;
    SearchView *search_;
}

@end

@implementation Cydia

- (void) _loaded {
    if ([broken_ count] != 0) {
        int count = [broken_ count];

        UIAlertSheet *sheet = [[[UIAlertSheet alloc]
            initWithTitle:[NSString stringWithFormat:@"%d Half-Installed Package%@", count, (count == 1 ? @"" : @"s")]
            buttons:[NSArray arrayWithObjects:
                @"Forcibly Clear",
                @"Ignore (Temporary)",
            nil]
            defaultButtonIndex:0
            delegate:self
            context:@"fixhalf"
        ] autorelease];

        [sheet setBodyText:@"When the shell scripts associated with packages fail, they are left in a state known as either half-configured or half-installed. These errors don't go away and instead continue to cause issues. These scripts can be deleted and the packages forcibly removed."];
        [sheet popupAlertAnimated:YES];
    } else if (!Ignored_ && [essential_ count] != 0) {
        int count = [essential_ count];

        UIAlertSheet *sheet = [[[UIAlertSheet alloc]
            initWithTitle:[NSString stringWithFormat:@"%d Essential Upgrade%@", count, (count == 1 ? @"" : @"s")]
            buttons:[NSArray arrayWithObjects:@"Upgrade Essential", @"Ignore (Temporary)", nil]
            defaultButtonIndex:0
            delegate:self
            context:@"upgrade"
        ] autorelease];

        [sheet setBodyText:@"One or more essential packages are currently out of date. If these packages are not upgraded you are likely to encounter errors."];
        [sheet popupAlertAnimated:YES];
    }
}

- (void) _reloadData {
    /*UIProgressHUD *hud = [[UIProgressHUD alloc] initWithWindow:window_];
    [hud setText:@"Reloading Data"];
    [overlay_ addSubview:hud];
    [hud show:YES];*/

    [database_ reloadData];

    if (Packages_ == nil) {
        Packages_ = [[NSMutableDictionary alloc] initWithCapacity:128];
        [Metadata_ setObject:Packages_ forKey:@"Packages"];
    }

    size_t changes(0);

    [essential_ removeAllObjects];
    [broken_ removeAllObjects];

    NSArray *packages = [database_ packages];
    for (int i(0), e([packages count]); i != e; ++i) {
        Package *package = [packages objectAtIndex:i];
        if ([package half])
            [broken_ addObject:package];
        if ([package upgradable]) {
            if ([package essential])
                [essential_ addObject:package];
            ++changes;
        }
    }

    if (changes != 0) {
        NSString *badge([[NSNumber numberWithInt:changes] stringValue]);
        [buttonbar_ setBadgeValue:badge forButton:3];
        if ([buttonbar_ respondsToSelector:@selector(setBadgeAnimated:forButton:)])
            [buttonbar_ setBadgeAnimated:YES forButton:3];
        [self setApplicationBadge:badge];
    } else {
        [buttonbar_ setBadgeValue:nil forButton:3];
        if ([buttonbar_ respondsToSelector:@selector(setBadgeAnimated:forButton:)])
            [buttonbar_ setBadgeAnimated:NO forButton:3];
        [self removeApplicationBadge];
    }

    if (Changed_) {
        _assert([Metadata_ writeToFile:@"/var/lib/cydia/metadata.plist" atomically:YES] == YES);
        Changed_ = false;
    }

    /* XXX: this is just stupid */
    if (tag_ != 2)
        [install_ reloadData];
    if (tag_ != 3)
        [changes_ reloadData];
    if (tag_ != 4)
        [manage_ reloadData];
    if (tag_ != 5)
        [search_ reloadData];

    [book_ reloadData];

    if ([packages count] == 0);
    else if (Loaded_)
        [self _loaded];
    else {
        Loaded_ = YES;
        [book_ update];
    }

    /*[hud show:NO];
    [hud removeFromSuperview];*/
}

- (void) reloadData {
    @synchronized (self) {
        if (confirm_ == nil)
            [self _reloadData];
    }
}

- (void) resolve {
    pkgProblemResolver *resolver = [database_ resolver];

    resolver->InstallProtect();
    if (!resolver->Resolve(true))
        _error->Discard();
}

- (void) perform {
    [database_ prepare];

    if ([database_ cache]->BrokenCount() == 0)
        confirm_ = [[ConfirmationView alloc] initWithView:underlay_ database:database_ delegate:self];
    else {
        NSMutableArray *broken = [NSMutableArray arrayWithCapacity:16];
        NSArray *packages = [database_ packages];

        for (size_t i(0); i != [packages count]; ++i) {
            Package *package = [packages objectAtIndex:i];
            if ([package broken])
                [broken addObject:[package name]];
        }

        UIAlertSheet *sheet = [[[UIAlertSheet alloc]
            initWithTitle:[NSString stringWithFormat:@"%d Broken Packages", [database_ cache]->BrokenCount()]
            buttons:[NSArray arrayWithObjects:@"Okay", nil]
            defaultButtonIndex:0
            delegate:self
            context:@"broken"
        ] autorelease];

        [sheet setBodyText:[NSString stringWithFormat:@"The following packages have unmet dependencies:\n\n%@", [broken componentsJoinedByString:@"\n"]]];
        [sheet popupAlertAnimated:YES];

        [self _reloadData];
    }
}

- (void) installPackage:(Package *)package {
    @synchronized (self) {
        [package install];
        [self resolve];
        [self perform];
    }
}

- (void) removePackage:(Package *)package {
    @synchronized (self) {
        [package remove];
        [self resolve];
        [self perform];
    }
}

- (void) distUpgrade {
    @synchronized (self) {
        [database_ upgrade];
        [self perform];
    }
}

- (void) cancel {
    @synchronized (self) {
        [confirm_ release];
        confirm_ = nil;
        [self _reloadData];
    }
}

- (void) confirm {
    [overlay_ removeFromSuperview];
    reload_ = true;

    [progress_
        detachNewThreadSelector:@selector(perform)
        toTarget:database_
        withObject:nil
        title:@"Running..."
    ];
}

- (void) bootstrap_ {
    [database_ update];
    [database_ upgrade];
    [database_ prepare];
    [database_ perform];
}

- (void) bootstrap {
    [progress_
        detachNewThreadSelector:@selector(bootstrap_)
        toTarget:self
        withObject:nil
        title:@"Bootstrap Install..."
    ];
}

- (void) progressViewIsComplete:(ProgressView *)progress {
    @synchronized (self) {
        [self _reloadData];

        if (confirm_ != nil) {
            [underlay_ addSubview:overlay_];
            [confirm_ removeFromSuperview];
            [confirm_ release];
            confirm_ = nil;
        }
    }
}

- (void) alertSheet:(UIAlertSheet *)sheet buttonClicked:(int)button {
    NSString *context = [sheet context];
    if ([context isEqualToString:@"fixhalf"])
        switch (button) {
            case 1:
                @synchronized (self) {
                    for (int i = 0, e = [broken_ count]; i != e; ++i) {
                        Package *broken = [broken_ objectAtIndex:i];
                        [broken remove];

                        NSString *id = [broken id];
                        unlink([[NSString stringWithFormat:@"/var/lib/dpkg/info/%@.prerm", id] UTF8String]);
                        unlink([[NSString stringWithFormat:@"/var/lib/dpkg/info/%@.postrm", id] UTF8String]);
                        unlink([[NSString stringWithFormat:@"/var/lib/dpkg/info/%@.preinst", id] UTF8String]);
                        unlink([[NSString stringWithFormat:@"/var/lib/dpkg/info/%@.postinst", id] UTF8String]);
                    }

                    [self resolve];
                    [self perform];
                }
            break;

            case 2:
                [broken_ removeAllObjects];
                [self _loaded];
            break;

            default:
                _assert(false);
        }
    else if ([context isEqualToString:@"upgrade"])
        switch (button) {
            case 1:
                @synchronized (self) {
                    for (int i = 0, e = [essential_ count]; i != e; ++i) {
                        Package *essential = [essential_ objectAtIndex:i];
                        [essential install];
                    }

                    [self resolve];
                    [self perform];
                }
            break;

            case 2:
                Ignored_ = YES;
            break;

            default:
                _assert(false);
        }

    [sheet dismiss];
}

- (void) setPage:(RVPage *)page {
    [page resetViewAnimated:NO];
    [page setDelegate:self];
    [book_ setPage:page];
}

- (RVPage *) _setHomePage {
    BrowserView *browser = [[[BrowserView alloc] initWithBook:book_ database:database_] autorelease];
    [self setPage:browser];
    [browser loadURL:[NSURL URLWithString:@"http://cydia.saurik.com/"]];
    return browser;
}

- (void) buttonBarItemTapped:(id)sender {
    unsigned tag = [sender tag];
    if (tag == tag_) {
        [book_ resetViewAnimated:YES];
        return;
    }

    switch (tag) {
        case 1: [self _setHomePage]; break;

        case 2: [self setPage:install_]; break;
        case 3: [self setPage:changes_]; break;
        case 4: [self setPage:manage_]; break;
        case 5: [self setPage:search_]; break;

        default: _assert(false);
    }

    tag_ = tag;
}

- (void) applicationWillSuspend {
    [super applicationWillSuspend];

    [database_ clean];

    if (reload_) {
        pid_t pid = ExecFork();
        if (pid == 0) {
            sleep(1);
            execlp("launchctl", "launchctl", "stop", "com.apple.SpringBoard", NULL);
            exit(0);
        }
    }
}

- (void) applicationDidFinishLaunching:(id)unused {
    _assert(pkgInitConfig(*_config));
    _assert(pkgInitSystem(*_config, _system));

    confirm_ = nil;
    tag_ = 1;

    essential_ = [[NSMutableArray alloc] initWithCapacity:4];
    broken_ = [[NSMutableArray alloc] initWithCapacity:4];

    CGRect screenrect = [UIHardware fullScreenApplicationContentRect];
    window_ = [[UIWindow alloc] initWithContentRect:screenrect];

    [window_ orderFront: self];
    [window_ makeKey: self];
    [window_ _setHidden: NO];

    database_ = [[Database alloc] init];
    progress_ = [[ProgressView alloc] initWithFrame:[window_ bounds] database:database_ delegate:self];
    [database_ setDelegate:progress_];
    [window_ setContentView:progress_];

    underlay_ = [[UIView alloc] initWithFrame:[progress_ bounds]];
    [progress_ setContentView:underlay_];

    overlay_ = [[UIView alloc] initWithFrame:[underlay_ bounds]];

    if (!bootstrap_)
        [underlay_ addSubview:overlay_];

    book_ = [[CYBook alloc] initWithFrame:CGRectMake(
        0, 0, screenrect.size.width, screenrect.size.height - 48
    ) database:database_];

    [book_ setDelegate:self];

    [overlay_ addSubview:book_];

    NSArray *buttonitems = [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"home-up.png", kUIButtonBarButtonInfo,
            @"home-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:1], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Home", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],

        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"install-up.png", kUIButtonBarButtonInfo,
            @"install-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:2], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Install", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],

        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"changes-up.png", kUIButtonBarButtonInfo,
            @"changes-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:3], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Changes", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],

        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"manage-up.png", kUIButtonBarButtonInfo,
            @"manage-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:4], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Manage", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],

        [NSDictionary dictionaryWithObjectsAndKeys:
            @"buttonBarItemTapped:", kUIButtonBarButtonAction,
            @"search-up.png", kUIButtonBarButtonInfo,
            @"search-dn.png", kUIButtonBarButtonSelectedInfo,
            [NSNumber numberWithInt:5], kUIButtonBarButtonTag,
            self, kUIButtonBarButtonTarget,
            @"Search", kUIButtonBarButtonTitle,
            @"0", kUIButtonBarButtonType,
        nil],
    nil];

    buttonbar_ = [[UIButtonBar alloc]
        initInView:overlay_
        withFrame:CGRectMake(
            0, screenrect.size.height - ButtonBarHeight_,
            screenrect.size.width, ButtonBarHeight_
        )
        withItemList:buttonitems
    ];

    [buttonbar_ setDelegate:self];
    [buttonbar_ setBarStyle:1];
    [buttonbar_ setButtonBarTrackingMode:2];

    int buttons[5] = {1, 2, 3, 4, 5};
    [buttonbar_ registerButtonGroup:0 withButtons:buttons withCount:5];
    [buttonbar_ showButtonGroup:0 withDuration:0];

    for (int i = 0; i != 5; ++i)
        [[buttonbar_ viewWithTag:(i + 1)] setFrame:CGRectMake(
            i * 64 + 2, 1, 60, ButtonBarHeight_
        )];

    [buttonbar_ showSelectionForButton:1];
    [overlay_ addSubview:buttonbar_];

    [UIKeyboard initImplementationNow];
    CGSize keysize = [UIKeyboard defaultSize];
    CGRect keyrect = {{0, [overlay_ bounds].size.height}, keysize};
    keyboard_ = [[UIKeyboard alloc] initWithFrame:keyrect];
    [[UIKeyboardImpl sharedInstance] setSoundsEnabled:(Sounds_Keyboard_ ? YES : NO)];
    [overlay_ addSubview:keyboard_];

    install_ = [[InstallView alloc] initWithBook:book_ database:database_];
    changes_ = [[ChangesView alloc] initWithBook:book_ database:database_];
    manage_ = [[ManageView alloc] initWithBook:book_ database:database_];
    search_ = [[SearchView alloc] initWithBook:book_ database:database_];

    [progress_ resetView];
    [self reloadData];

    if (bootstrap_)
        [self bootstrap];
    else
        [self _setHomePage];
}

- (void) showKeyboard:(BOOL)show {
    CGSize keysize = [UIKeyboard defaultSize];
    CGRect keydown = {{0, [overlay_ bounds].size.height}, keysize};
    CGRect keyup = keydown;
    keyup.origin.y -= keysize.height;

    UIFrameAnimation *animation = [[[UIFrameAnimation alloc] initWithTarget:keyboard_] autorelease];
    [animation setSignificantRectFields:2];

    if (show) {
        [animation setStartFrame:keydown];
        [animation setEndFrame:keyup];
        [keyboard_ activate];
    } else {
        [animation setStartFrame:keyup];
        [animation setEndFrame:keydown];
        [keyboard_ deactivate];
    }

    [[UIAnimator sharedAnimator]
        addAnimations:[NSArray arrayWithObjects:animation, nil]
        withDuration:KeyboardTime_
        start:YES
    ];
}

- (void) slideUp:(UIAlertSheet *)alert {
    if (Advanced_)
        [alert presentSheetFromButtonBar:buttonbar_];
    else
        [alert presentSheetInView:overlay_];
}

@end

void AddPreferences(NSString *plist) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSMutableDictionary *settings = [[[NSMutableDictionary alloc] initWithContentsOfFile:plist] autorelease];
    _assert(settings != NULL);
    NSMutableArray *items = [settings objectForKey:@"items"];

    bool cydia(false);

    for (size_t i(0); i != [items count]; ++i) {
        NSMutableDictionary *item([items objectAtIndex:i]);
        NSString *label = [item objectForKey:@"label"];
        if (label != nil && [label isEqualToString:@"Cydia"]) {
            cydia = true;
            break;
        }
    }

    if (!cydia) {
        for (size_t i(0); i != [items count]; ++i) {
            NSDictionary *item([items objectAtIndex:i]);
            NSString *label = [item objectForKey:@"label"];
            if (label != nil && [label isEqualToString:@"General"]) {
                [items insertObject:[NSDictionary dictionaryWithObjectsAndKeys:
                    @"CydiaSettings", @"bundle",
                    @"PSLinkCell", @"cell",
                    [NSNumber numberWithBool:YES], @"hasIcon",
                    [NSNumber numberWithBool:YES], @"isController",
                    @"Cydia", @"label",
                nil] atIndex:(i + 1)];

                break;
            }
        }

        _assert([settings writeToFile:plist atomically:YES] == YES);
    }

    [pool release];
}

/*IMP alloc_;
id Alloc_(id self, SEL selector) {
    id object = alloc_(self, selector);
    fprintf(stderr, "[%s]A-%p\n", self->isa->name, object);
    return object;
}*/

/*IMP dealloc_;
id Dealloc_(id self, SEL selector) {
    id object = dealloc_(self, selector);
    fprintf(stderr, "[%s]D-%p\n", self->isa->name, object);
    return object;
}*/

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    bootstrap_ = argc > 1 && strcmp(argv[1], "--bootstrap") == 0;

    Home_ = NSHomeDirectory();

    {
        NSString *plist = [Home_ stringByAppendingString:@"/Library/Preferences/com.apple.preferences.sounds.plist"];
        if (NSDictionary *sounds = [NSDictionary dictionaryWithContentsOfFile:plist])
            if (NSNumber *keyboard = [sounds objectForKey:@"keyboard"])
                Sounds_Keyboard_ = [keyboard boolValue];
    }

    setuid(0);
    setgid(0);

    /*Method alloc = class_getClassMethod([NSObject class], @selector(alloc));
    alloc_ = alloc->method_imp;
    alloc->method_imp = (IMP) &Alloc_;*/

    /*Method dealloc = class_getClassMethod([NSObject class], @selector(dealloc));
    dealloc_ = dealloc->method_imp;
    dealloc->method_imp = (IMP) &Dealloc_;*/

    if (NSDictionary *sysver = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"]) {
        if (NSString *prover = [sysver valueForKey:@"ProductVersion"]) {
            Firmware_ = strdup([prover UTF8String]);
            NSArray *versions = [prover componentsSeparatedByString:@"."];
            int count = [versions count];
            Major_ = count > 0 ? [[versions objectAtIndex:0] intValue] : 0;
            Minor_ = count > 1 ? [[versions objectAtIndex:1] intValue] : 0;
            BugFix_ = count > 2 ? [[versions objectAtIndex:2] intValue] : 0;
        }
    }

    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = new char[size];
    sysctlbyname("hw.machine", machine, &size, NULL, 0);
    Machine_ = machine;

    if (CFMutableDictionaryRef dict = IOServiceMatching("IOPlatformExpertDevice"))
        if (io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, dict)) {
            if (CFTypeRef serial = IORegistryEntryCreateCFProperty(service, CFSTR(kIOPlatformSerialNumberKey), kCFAllocatorDefault, 0)) {
                SerialNumber_ = strdup(CFStringGetCStringPtr((CFStringRef) serial, CFStringGetSystemEncoding()));
                CFRelease(serial);
            }

            IOObjectRelease(service);
        }

    /*AddPreferences(@"/Applications/Preferences.app/Settings-iPhone.plist");
    AddPreferences(@"/Applications/Preferences.app/Settings-iPod.plist");*/

    if ((Metadata_ = [[NSMutableDictionary alloc] initWithContentsOfFile:@"/var/lib/cydia/metadata.plist"]) == NULL)
        Metadata_ = [[NSMutableDictionary alloc] initWithCapacity:2];
    else
        Packages_ = [Metadata_ objectForKey:@"Packages"];

    if (access("/User", F_OK) != 0)
        system("/usr/libexec/cydia/firmware.sh");

    space_ = CGColorSpaceCreateDeviceRGB();

    Blueish_.Set(space_, 0x19/255.f, 0x32/255.f, 0x50/255.f, 1.0);
    Black_.Set(space_, 0.0, 0.0, 0.0, 1.0);
    Clear_.Set(space_, 0.0, 0.0, 0.0, 0.0);
    Red_.Set(space_, 1.0, 0.0, 0.0, 1.0);
    White_.Set(space_, 1.0, 1.0, 1.0, 1.0);

    int value = UIApplicationMain(argc, argv, [Cydia class]);

    CGColorSpaceRelease(space_);

    [pool release];
    return value;
}
