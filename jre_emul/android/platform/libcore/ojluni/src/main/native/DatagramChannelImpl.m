/*
 * Copyright (c) 2001, 2008, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

#include "java/net/PortUnreachableException.h"
#include "jni.h"
#include "jni_util.h"
#include "jvm.h"
#include "jlong.h"

#include <netdb.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#if defined(__linux__) || defined(_ALLBSD_SOURCE)
#include <netinet/in.h>
#endif

#include "net_util.h"
#include "net_util_md.h"
#include "nio.h"
#include "nio_util.h"

static jfieldID dci_senderID;   /* sender in sun.nio.ch.DatagramChannelImpl */
static jfieldID dci_senderAddrID; /* sender InetAddress in sun.nio.ch.DatagramChannelImpl */
static jfieldID dci_senderPortID; /* sender port in sun.nio.ch.DatagramChannelImpl */
static jclass isa_class;        /* java.net.InetSocketAddress */
static jmethodID isa_ctorID;    /*   .InetSocketAddress(InetAddress, int) */

JNIEXPORT void JNICALL
Java_sun_nio_ch_DatagramChannelImpl_initIDs(JNIEnv *env, jclass clazz)
{
    clazz = (*env)->FindClass(env, "java/net/InetSocketAddress");
    isa_class = (*env)->NewGlobalRef(env, clazz);
    [(id)isa_class retain];
    isa_ctorID = (*env)->GetMethodID(env, clazz, "<init>",
                                     "(Ljava/net/InetAddress;I)V");
    [(id)isa_ctorID retain];
    clazz = (*env)->FindClass(env, "sun/nio/ch/DatagramChannelImpl");
    dci_senderID = (*env)->GetFieldID(env, clazz, "sender",
                                      "Ljava/net/SocketAddress;");
    [(id)dci_senderID retain];
    dci_senderAddrID = (*env)->GetFieldID(env, clazz,
                                          "cachedSenderInetAddress",
                                          "Ljava/net/InetAddress;");
    [(id)dci_senderAddrID retain];
    dci_senderPortID = (*env)->GetFieldID(env, clazz,
                                          "cachedSenderPort", "I");
    [(id)dci_senderPortID retain];
}

JNIEXPORT void JNICALL Java_sun_nio_ch_DatagramChannelImpl_disconnect0(JNIEnv *env, jobject this,
                                                                       jobject fdo, bool isIPv6) {
  jint fd = fdval(env, fdo);
  int rv = 0;

#ifdef __solaris__
    rv = connect(fd, 0, 0);
#endif

#if defined(__linux__) || defined(_ALLBSD_SOURCE)
    {
        int len;
        SOCKADDR sa;

        memset(&sa, 0, sizeof(sa));

#ifdef AF_INET6
        if (isIPv6) {
            struct sockaddr_in6 *him6 = (struct sockaddr_in6 *)&sa;
#if defined(_ALLBSD_SOURCE)
            him6->sin6_family = AF_INET6;
#else
            him6->sin6_family = AF_UNSPEC;
#endif
            len = sizeof(struct sockaddr_in6);
        } else
#endif
        {
            struct sockaddr_in *him4 = (struct sockaddr_in*)&sa;
#if defined(_ALLBSD_SOURCE)
            him4->sin_family = AF_INET;
#else
            him4->sin_family = AF_UNSPEC;
#endif
            len = sizeof(struct sockaddr_in);
        }

        rv = connect(fd, (struct sockaddr *)&sa, len);

#if defined(_ALLBSD_SOURCE)
        if (rv < 0 && errno == EADDRNOTAVAIL)
                rv = errno = 0;
#endif
    }
#endif

    if (rv < 0)
        handleSocketError(env, errno);
}

JNIEXPORT jint JNICALL Java_sun_nio_ch_DatagramChannelImpl_receive0(JNIEnv *env, jobject this,
                                                                    jobject fdo, jlong address,
                                                                    jint len, bool connected) {
  jint fd = fdval(env, fdo);
  void *buf = (void *)jlong_to_ptr(address);
  SOCKADDR sa;
  socklen_t sa_len = SOCKADDR_LEN;
  bool retry = JNI_FALSE;
  jint n = 0;
  jobject senderAddr;

  if (len > MAX_PACKET_LEN) {
    len = MAX_PACKET_LEN;
  }

  memset(&sa, 0, sa_len);

  do {
    retry = JNI_FALSE;
    n = (int)recvfrom(fd, buf, len, 0, (struct sockaddr *)&sa, &sa_len);
    if (n < 0) {
      if (errno == EWOULDBLOCK) {
        return IOS_UNAVAILABLE;
      }
      if (errno == EINTR) {
        return IOS_INTERRUPTED;
      }
      if (errno == ECONNREFUSED) {
        if (connected == JNI_FALSE) {
          retry = JNI_TRUE;
        } else {
          J2ObjCThrowByName(JavaNetPortUnreachableException, nil);
          return IOS_THROWN;
        }
      } else {
        return handleSocketError(env, errno);
      }
    }
  } while (retry == JNI_TRUE);

  // Peer (or other thread) has performed an orderly shutdown, sockaddr will be
  // invalid.
  if (n == 0 && ((struct sockaddr *)&sa)->sa_family == 0) {
    // zero the sender field, so receive() returns null and not
    // random garbage
    (*env)->SetObjectField(env, this, dci_senderID, NULL);
    return n;
  }

  /*
   * If the source address and port match the cached address
   * and port in DatagramChannelImpl then we don't need to
   * create InetAddress and InetSocketAddress objects.
   */
  senderAddr = (*env)->GetObjectField(env, this, dci_senderAddrID);
  if (senderAddr != NULL) {
    if (!NET_SockaddrEqualsInetAddress(env, (struct sockaddr *)&sa, senderAddr)) {
      senderAddr = NULL;
    } else {
      jint port = (*env)->GetIntField(env, this, dci_senderPortID);
      if (port != NET_GetPortFromSockaddr((struct sockaddr *)&sa)) {
        senderAddr = NULL;
      }
    }
  }
  if (senderAddr == NULL) {
    jobject isa = NULL;
    int port;
    jobject ia = NET_SockaddrToInetAddress(env, (struct sockaddr *)&sa, &port);

    if (ia != NULL) {
      isa = (*env)->NewObject(env, isa_class, isa_ctorID, ia, port);
    }

    if (isa == NULL) {
      JNU_ThrowOutOfMemoryError(env, "heap allocation failed");
      return IOS_THROWN;
    }

    (*env)->SetObjectField(env, this, dci_senderAddrID, ia);
    (*env)->SetIntField(env, this, dci_senderPortID,
                        NET_GetPortFromSockaddr((struct sockaddr *)&sa));
    (*env)->SetObjectField(env, this, dci_senderID, isa);
  }
  return n;
}

JNIEXPORT jint JNICALL Java_sun_nio_ch_DatagramChannelImpl_send0(JNIEnv *env, jobject this,
                                                                 bool preferIPv6, jobject fdo,
                                                                 jlong address, jint len,
                                                                 jobject destAddress,
                                                                 jint destPort) {
  jint fd = fdval(env, fdo);
  void *buf = (void *)jlong_to_ptr(address);
  SOCKADDR sa;
  int sa_len = SOCKADDR_LEN;
  jint n = 0;

  if (len > MAX_PACKET_LEN) {
    len = MAX_PACKET_LEN;
  }

  if (NET_InetAddressToSockaddr(env, destAddress, destPort, (struct sockaddr *)&sa, &sa_len,
                                preferIPv6) != 0) {
    return IOS_THROWN;
  }

  n = (int)sendto(fd, buf, len, 0, (struct sockaddr *)&sa, sa_len);
  if (n < 0) {
    if (errno == EAGAIN) {
      return IOS_UNAVAILABLE;
    }
    if (errno == EINTR) {
      return IOS_INTERRUPTED;
    }
    if (errno == ECONNREFUSED) {
      J2ObjCThrowByName(JavaNetPortUnreachableException, nil);
      return IOS_THROWN;
    }
    return handleSocketError(env, errno);
  }
  return n;
}
/* J2ObjC: unused.
static JNINativeMethod gMethods[] = {
  NATIVE_METHOD(DatagramChannelImpl, initIDs, "()V"),
  NATIVE_METHOD(DatagramChannelImpl, disconnect0, "(Ljava/io/FileDescriptor;Z)V"),
  NATIVE_METHOD(DatagramChannelImpl, receive0, "(Ljava/io/FileDescriptor;JIZ)I"),
  NATIVE_METHOD(DatagramChannelImpl, send0, "(ZLjava/io/FileDescriptor;JILjava/net/InetAddress;I)I"),
};

void register_sun_nio_ch_DatagramChannelImpl(JNIEnv* env) {
  jniRegisterNativeMethods(env, "sun/nio/ch/DatagramChannelImpl", gMethods, NELEM(gMethods));
}
*/
