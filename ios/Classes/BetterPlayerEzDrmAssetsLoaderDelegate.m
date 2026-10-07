// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "BetterPlayerEzDrmAssetsLoaderDelegate.h"

@implementation BetterPlayerEzDrmAssetsLoaderDelegate

NSString *_assetId;

NSString * DEFAULT_LICENSE_SERVER_URL = @"https://fps.ezdrm.com/api/licenses/";

- (instancetype)init:(NSURL *)certificateURL withLicenseURL:(NSURL *)licenseURL{
    self = [super init];
    _certificateURL = certificateURL;
    _licenseURL = licenseURL;
    return self;
}

- (NSString *)redactedLicenseURLString:(NSString *)urlString {
    if (urlString.length == 0) {
        return @"(empty)";
    }
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"(?i)(CustomData=)([^&]*)"
                                                  options:0
                                                    error:nil];
    return [regex stringByReplacingMatchesInString:urlString
                                           options:0
                                             range:NSMakeRange(0, urlString.length)
                                      withTemplate:@"$1<redacted>"];
}

- (NSString *)previewDataAsText:(NSData *)data maxLength:(NSUInteger)maxLength {
    if (data == nil || data.length == 0) {
        return @"(empty)";
    }
    NSString *asText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (asText.length == 0) {
        return [NSString stringWithFormat:@"(binary %lu bytes)", (unsigned long)data.length];
    }
    NSString *trimmed = [asText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > maxLength) {
        return [[trimmed substringToIndex:maxLength] stringByAppendingString:@"…"];
    }
    return trimmed;
}

- (void)logCkcPrefix:(NSData *)data {
    if (data == nil || data.length == 0) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM CKC prefix: (empty)");
        return;
    }
    NSUInteger previewLen = MIN((NSUInteger)16, data.length);
    const unsigned char *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:previewLen * 3];
    for (NSUInteger i = 0; i < previewLen; i++) {
        [hex appendFormat:@"%02X ", bytes[i]];
    }
    NSData *prefix = [data subdataWithRange:NSMakeRange(0, previewLen)];
    NSString *asAscii = [[NSString alloc] initWithData:prefix encoding:NSASCIIStringEncoding];
    BOOL looksText = NO;
    if (asAscii.length > 0) {
        unichar first = [asAscii characterAtIndex:0];
        looksText = (first == '{' || first == '[' || first == '<' ||
                     [asAscii hasPrefix:@"eyJ"] || [asAscii hasPrefix:@"CKC"] ||
                     [asAscii hasPrefix:@"ckc"]);
    }
    NSLog(@"[BetterPlayer-FairPlay] EzDRM CKC hex[0..%lu]=%@", (unsigned long)previewLen, hex);
    NSLog(@"[BetterPlayer-FairPlay] EzDRM CKC ascii[0..%lu]=%@ looksText=%@",
          (unsigned long)previewLen,
          asAscii.length > 0 ? asAscii : @"(non-ascii)",
          looksText ? @"YES" : @"NO");
}

/// Classic EZDRM: https://fps.ezdrm.com/api/licenses/{ASSET_ID}?customdata=...
/// Modern auth URL from backend: .../api/licenses/auth?pX=...&CustomData=<JWT>
/// — already complete; appending assetId would corrupt CustomData.
- (BOOL)isCompleteLicenseURL:(NSURL *)licenseURL {
    if (licenseURL == nil || licenseURL == (id)[NSNull null]) {
        return NO;
    }
    NSString *absolute = licenseURL.absoluteString ?: @"";
    NSString *lower = absolute.lowercaseString;
    if (absolute.length == 0) {
        return NO;
    }
    if ([absolute containsString:@"?"]) {
        return YES;
    }
    if ([lower containsString:@"/auth"]) {
        return YES;
    }
    if ([lower containsString:@"customdata="]) {
        return YES;
    }
    return NO;
}

- (NSURL *)licenseServerURLForAssetId:(NSString *)assetId customParams:(NSString *)customParams {
    NSURL *finalLicenseURL;
    if (_licenseURL != nil && _licenseURL != (id)[NSNull null]) {
        finalLicenseURL = _licenseURL;
    } else {
        finalLicenseURL = [[NSURL alloc] initWithString:DEFAULT_LICENSE_SERVER_URL];
    }

    if ([self isCompleteLicenseURL:finalLicenseURL]) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM using complete license URL as-is: %@",
              [self redactedLicenseURLString:finalLicenseURL.absoluteString]);
        return finalLicenseURL;
    }

    NSString *composed = [NSString stringWithFormat:@"%@%@%@", finalLicenseURL.absoluteString, assetId ?: @"", customParams ?: @""];
    NSLog(@"[BetterPlayer-FairPlay] EzDRM classic license URL: %@",
          [self redactedLicenseURLString:composed]);
    return [[NSURL alloc] initWithString:composed];
}

/*------------------------------------------
 **
 ** getContentKeyAndLeaseExpiryFromKeyServerModuleWithRequest
 **
 ** Takes the bundled SPC and sends it to the license server defined at licenseUrl or KEY_SERVER_URL (if licenseUrl is null).
 ** It returns CKC.
 ** ---------------------------------------*/
- (NSData *)getContentKeyAndLeaseExpiryFromKeyServerModuleWithRequest:(NSData*)requestBytes and:(NSString *)assetId and:(NSString *)customParams and:(NSError *)errorOut {
    NSData * decodedData;
    NSURLResponse * response;
    NSError * requestError = nil;

    NSURL * ksmURL = [self licenseServerURLForAssetId:assetId customParams:customParams];
    if (ksmURL == nil) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM license URL is nil");
        return nil;
    }

    NSLog(@"[BetterPlayer-FairPlay] EzDRM posting SPC (%lu bytes) to license server",
          (unsigned long)(requestBytes != nil ? requestBytes.length : 0));

    NSMutableURLRequest * request = [[NSMutableURLRequest alloc] initWithURL:ksmURL];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-type"];
    [request setHTTPBody:requestBytes];
    [request setTimeoutInterval:30.0];

    @try {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM license request starting…");
        decodedData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&requestError];
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSInteger statusCode = httpResponse.statusCode;
            NSUInteger byteCount = decodedData != nil ? decodedData.length : 0;
            NSLog(@"[BetterPlayer-FairPlay] EzDRM license HTTP %ld, ckcBytes=%lu",
                  (long)statusCode,
                  (unsigned long)byteCount);
            if (statusCode < 200 || statusCode >= 300 || byteCount == 0) {
                NSLog(@"[BetterPlayer-FairPlay] EzDRM license response preview: %@",
                      [self previewDataAsText:decodedData maxLength:300]);
                [self logCkcPrefix:decodedData];
            } else {
                NSLog(@"[BetterPlayer-FairPlay] EzDRM CKC received successfully (%lu bytes)",
                      (unsigned long)byteCount);
                [self logCkcPrefix:decodedData];
            }
        } else if (response != nil) {
            NSLog(@"[BetterPlayer-FairPlay] EzDRM license non-HTTP response: %@, bytes=%lu",
                  NSStringFromClass(response.class),
                  (unsigned long)(decodedData != nil ? decodedData.length : 0));
        } else {
            NSLog(@"[BetterPlayer-FairPlay] EzDRM license response was nil, bytes=%lu",
                  (unsigned long)(decodedData != nil ? decodedData.length : 0));
        }
        if (requestError != nil) {
            NSLog(@"[BetterPlayer-FairPlay] EzDRM license request error: %@ (domain=%@ code=%ld)",
                  requestError.localizedDescription,
                  requestError.domain,
                  (long)requestError.code);
        }
    }
    @catch (NSException* excp) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM license request exception: %@", excp.reason ?: @"unknown");
    }
    return decodedData;
}

/*------------------------------------------
 **
 ** getAppCertificate
 **
 ** returns the apps certificate for authenticating against your server
 ** the example here uses a local certificate
 ** but you may need to edit this function to point to your certificate
 ** ---------------------------------------*/
- (NSData *)getAppCertificate:(NSString *) String {
    NSData * certificate = nil;
    if (_certificateURL == nil || _certificateURL == (id)[NSNull null]) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM certificateURL is nil");
        return nil;
    }
    NSLog(@"[BetterPlayer-FairPlay] EzDRM fetching certificate: %@", _certificateURL.absoluteString);
    NSError *certError = nil;
    certificate = [NSData dataWithContentsOfURL:_certificateURL options:0 error:&certError];
    if (certError != nil) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM certificate fetch error: %@", certError.localizedDescription);
    }
    NSLog(@"[BetterPlayer-FairPlay] EzDRM certificate bytes=%lu",
          (unsigned long)(certificate != nil ? certificate.length : 0));
    return certificate;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURL *assetURI = loadingRequest.request.URL;
    NSString * str = assetURI.absoluteString;
    NSString * scheme = assetURI.scheme;
    if (!([scheme isEqualToString: @"skd"])){
        NSLog(@"[BetterPlayer-FairPlay] EzDRM ignoring non-skd scheme: %@", scheme ?: @"(nil)");
        return NO;
    }

    NSLog(@"[BetterPlayer-FairPlay] EzDRM FairPlay key request started skd=%@", str ?: @"(nil)");

    // EZDRM skd form: skd://fps.ezdrm.com/;{ASSET_ID} — content id must be the Asset ID UUID.
    NSString *assetId = nil;
    NSRange semicolonRange = [str rangeOfString:@";" options:NSBackwardsSearch];
    if (semicolonRange.location != NSNotFound && semicolonRange.location + 1 < str.length) {
        assetId = [str substringFromIndex:semicolonRange.location + 1];
    } else if (str.length >= 36) {
        assetId = [str substringFromIndex:str.length - 36];
    } else {
        assetId = str;
    }
    NSRange queryRange = [assetId rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        assetId = [assetId substringToIndex:queryRange.location];
    }
    _assetId = assetId;
    NSLog(@"[BetterPlayer-FairPlay] EzDRM assetId=%@", _assetId ?: @"(nil)");

    NSData * requestBytes = nil;
    NSData * certificate = nil;

    @try {
        certificate = [self getAppCertificate:_assetId];
    }
    @catch (NSException* excp) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM certificate exception: %@", excp.reason ?: @"unknown");
        [loadingRequest finishLoadingWithError:[[NSError alloc] initWithDomain:NSURLErrorDomain code:NSURLErrorClientCertificateRejected userInfo:nil]];
        return YES;
    }

    if (certificate == nil || certificate.length == 0) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM aborting: certificate is empty");
        [loadingRequest finishLoadingWithError:[[NSError alloc] initWithDomain:NSURLErrorDomain code:NSURLErrorClientCertificateRejected userInfo:nil]];
        return YES;
    }

    NSData *contentIdData = [_assetId dataUsingEncoding:NSUTF8StringEncoding];
    if (contentIdData == nil || contentIdData.length == 0) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM aborting: contentIdentifier is empty");
        [loadingRequest finishLoadingWithError:[[NSError alloc] initWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil]];
        return YES;
    }

    NSError *spcError = nil;
    @try {
        requestBytes = [loadingRequest streamingContentKeyRequestDataForApp:certificate
                                                          contentIdentifier:contentIdData
                                                                    options:nil
                                                                      error:&spcError];
    }
    @catch (NSException* excp) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM SPC exception: %@", excp.reason ?: @"unknown");
        [loadingRequest finishLoadingWithError:nil];
        return YES;
    }

    if (spcError != nil) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM SPC error: %@ (domain=%@ code=%ld)",
              spcError.localizedDescription,
              spcError.domain,
              (long)spcError.code);
    }
    if (requestBytes == nil || requestBytes.length == 0) {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM aborting: SPC is empty");
        [loadingRequest finishLoadingWithError:spcError];
        return YES;
    }
    NSLog(@"[BetterPlayer-FairPlay] EzDRM SPC created (contentId=%@, spcBytes=%lu)",
          _assetId,
          (unsigned long)requestBytes.length);

    NSString * passthruParams = [NSString stringWithFormat:@"?customdata=%@", _assetId];
    NSData * responseData;
    NSError * error;

    responseData = [self getContentKeyAndLeaseExpiryFromKeyServerModuleWithRequest:requestBytes and:_assetId and:passthruParams and:error];

    if (responseData != nil && responseData != NULL && ![responseData.class isKindOfClass:NSNull.class] && responseData.length > 0){
        if (loadingRequest.contentInformationRequest != nil) {
            loadingRequest.contentInformationRequest.contentType = AVStreamingKeyDeliveryContentKeyType;
        }
        AVAssetResourceLoadingDataRequest * dataRequest = loadingRequest.dataRequest;
        [dataRequest respondWithData:responseData];
        [loadingRequest finishLoading];
        NSLog(@"[BetterPlayer-FairPlay] EzDRM finished loading with CKC (%lu bytes)",
              (unsigned long)responseData.length);
    } else {
        NSLog(@"[BetterPlayer-FairPlay] EzDRM finished loading with error (nil/empty CKC)");
        [loadingRequest finishLoadingWithError:error];
    }

    return YES;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
    return [self resourceLoader:resourceLoader shouldWaitForLoadingOfRequestedResource:renewalRequest];
}

@end
