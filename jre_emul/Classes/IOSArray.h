// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//
//  IOSArray.h
//  JreEmulation
//

#ifndef IOSARRAY_H
#define IOSARRAY_H

#import "J2ObjC_common.h"
#import "NSObject+JavaObject.h"

#import <Foundation/NSArray.h>

@class IOSClass;

/**
 * An abstract class that represents a Java array.  Like a Java array,
 * an IOSArray is fixed-size but its elements are mutable.
 */
@interface IOSArray<__covariant ObjectType> : NSMutableArray<ObjectType> {
 @public
  /**
   * Size of the array. This field is read-only, visible only for
   * performance reasons. DO NOT MODIFY.
   */
  int32_t size_;
}

/** Returns the size of this array. */
- (int32_t)length;

/** Returns the description of a specified element in the array. */
- (NSString *)descriptionOfElementAtIndex:(int32_t)index;

/** Returns the element type of this array. */
- (IOSClass *)elementType;

/** Creates and returns an array containing the values from this array. */
- (id)java_clone;

/**
 * @brief Returns a pointer to the underlying array of elements.
 * The returned value is a raw pointer, so there are no index or
 * range checks. It is equivalent to the "IOS*Array_GetRef(array, 0)"
 * functions.
 */
- (void *)buffer;

@end

CF_EXTERN_C_BEGIN
void IOSArray_throwOutOfBoundsWithMsg(int32_t size, int32_t index);
void IOSArray_throwRangeOutOfBounds(int32_t size, int32_t offset, int32_t length);
CF_EXTERN_C_END

/** Implements the IOSArray |checkIndex| method as a C function. */
__attribute__((always_inline)) inline void IOSArray_checkIndex(int32_t size, int32_t index) {
  if (__builtin_expect(index < 0 || index >= size, 0)) {
    IOSArray_throwOutOfBoundsWithMsg(size, index);
  }
}

/** Implements the IOSArray |checkRange| method as a C function. */
__attribute__((always_inline)) inline void IOSArray_checkRange(
    int32_t size, int32_t offset, int32_t length) {
  if (__builtin_expect(length < 0 || offset < 0 || offset + length > size, 0)) {
    IOSArray_throwRangeOutOfBounds(size, offset, length);
  }
}

#endif // IOSARRAY_H
