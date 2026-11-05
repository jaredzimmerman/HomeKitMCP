#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Exception-safe access to Objective-C objects for the private_ tools. Every call checks
/// respondsToSelector first and catches Objective-C exceptions, so a missing or changed
/// private selector returns an error string instead of crashing the bridge.

/// Reads `key` with valueForKey:. Returns nil on success (value in *outValue) or an error string.
NSString * _Nullable HBSafeValueForKey(id object, NSString *key, id _Nullable * _Nullable outValue);

/// Property names declared on the object's class and its superclasses up to NSObject.
NSArray<NSString *> *HBPropertyNames(id object);

/// Instance method selector names declared on the object's class and superclasses up to NSObject.
NSArray<NSString *> *HBMethodNames(id object);

/// Loaded Objective-C class names starting with prefix (e.g. "HM").
NSArray<NSString *> *HBClassNames(NSString *prefix);

/// Calls selector on target. Supported shapes, checked against the method signature first:
///   - object arguments only, returning an object, a number, BOOL or void (synchronous)
///   - object arguments then a final completion block taking one NSError* (asynchronous)
/// Returns nil when the call was made (completion runs later or immediately), or an error string.
NSString * _Nullable HBSafeInvoke(id target, NSString *selectorName, NSArray *arguments,
                                  void (^completion)(id _Nullable result, NSError * _Nullable error));

NS_ASSUME_NONNULL_END
