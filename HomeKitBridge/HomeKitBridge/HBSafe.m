#import "HBSafe.h"
#import <objc/runtime.h>

NSString *HBSafeValueForKey(id object, NSString *key, id *outValue) {
    if (![object respondsToSelector:NSSelectorFromString(key)]) {
        return [NSString stringWithFormat:@"%@ does not respond to %@", NSStringFromClass([object class]), key];
    }
    @try {
        id v = [object valueForKey:key];
        if (outValue) *outValue = v;
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
}

NSArray<NSString *> *HBPropertyNames(id object) {
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    for (Class c = [object class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        objc_property_t *props = class_copyPropertyList(c, &n);
        for (unsigned int i = 0; i < n; i++) [names addObject:@(property_getName(props[i]))];
        free(props);
    }
    return names.array;
}

NSArray<NSString *> *HBMethodNames(id object) {
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    for (Class c = [object class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *methods = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) [names addObject:NSStringFromSelector(method_getName(methods[i]))];
        free(methods);
    }
    return names.array;
}

NSArray<NSString *> *HBClassNames(NSString *prefix) {
    NSMutableArray *out = [NSMutableArray array];
    unsigned int n = 0;
    Class *classes = objc_copyClassList(&n);
    for (unsigned int i = 0; i < n; i++) {
        NSString *name = @(class_getName(classes[i]));
        if ([name hasPrefix:prefix]) [out addObject:name];
    }
    free(classes);
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL HBIsObjectType(const char *t) { return t && t[0] == '@' && t[1] != '?'; }
static BOOL HBIsBlockType(const char *t) { return t && t[0] == '@' && t[1] == '?'; }

NSString *HBSafeInvoke(id target, NSString *selectorName, NSArray *arguments,
                       void (^completion)(id result, NSError *error)) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel]) {
        return [NSString stringWithFormat:@"%@ does not respond to %@", NSStringFromClass([target class]), selectorName];
    }
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return @"no method signature";
    NSUInteger argc = sig.numberOfArguments - 2;
    BOOL hasBlock = argc > 0 && HBIsBlockType([sig getArgumentTypeAtIndex:argc + 1]);
    NSUInteger objectArgs = hasBlock ? argc - 1 : argc;
    if (objectArgs != arguments.count) {
        return [NSString stringWithFormat:@"%@ takes %lu object argument(s)%@, got %lu", selectorName,
                (unsigned long)objectArgs, hasBlock ? @" plus a completion block" : @"", (unsigned long)arguments.count];
    }
    for (NSUInteger i = 0; i < objectArgs; i++) {
        if (!HBIsObjectType([sig getArgumentTypeAtIndex:i + 2])) {
            return [NSString stringWithFormat:@"argument %lu of %@ is not an object (%s); not supported",
                    (unsigned long)i, selectorName, [sig getArgumentTypeAtIndex:i + 2]];
        }
    }
    if (hasBlock && ![selectorName hasSuffix:@"completionHandler:"] && ![selectorName hasSuffix:@"completion:"]) {
        return @"only completion blocks named completionHandler: or completion: are supported";
    }
    const char *ret = sig.methodReturnType;
    if (!(ret[0] == 'v' || HBIsObjectType(ret) || strchr("BcCiIsSlLqQfd", ret[0]))) {
        return [NSString stringWithFormat:@"return type %s not supported", ret];
    }
    @try {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = target;
        inv.selector = sel;
        for (NSUInteger i = 0; i < objectArgs; i++) {
            id arg = arguments[i] == [NSNull null] ? nil : arguments[i];
            [inv setArgument:&arg atIndex:i + 2];
        }
        void (^block)(id) = nil;
        if (hasBlock) {
            // Only the first block argument is read. HomeKit completions are ^(NSError *) or
            // ^(id result, NSError *); for the second shape the first argument is the result and the
            // error is not seen. Classifying by class means a result object is never treated as an error.
            block = ^(id first) {
                NSError *error = [first isKindOfClass:[NSError class]] ? first : nil;
                id result = error ? nil : first;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
            };
            [inv setArgument:&block atIndex:argc + 1];
        }
        [inv retainArguments];
        [inv invoke];
        if (hasBlock) return nil;
        id result = nil;
        if (HBIsObjectType(ret)) { __unsafe_unretained id r = nil; [inv getReturnValue:&r]; result = r; }
        else if (ret[0] == 'B') { BOOL b; [inv getReturnValue:&b]; result = @(b); }
        else if (ret[0] == 'd') { double d; [inv getReturnValue:&d]; result = @(d); }
        else if (ret[0] == 'f') { float f; [inv getReturnValue:&f]; result = @(f); }
        else if (ret[0] != 'v') { long long q = 0; [inv getReturnValue:&q]; result = @(q); }
        completion(result, nil);
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
}
