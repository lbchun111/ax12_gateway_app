#include <android/log.h>
#include <ctype.h>
#include <jni.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include <dds/dds.h>

#include "generated/unitree_api.h"

#define LOG_TAG "UnitreeDds"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static dds_entity_t g_domain = DDS_RETCODE_ERROR;
static dds_entity_t g_participant = DDS_RETCODE_ERROR;
static dds_entity_t g_request_topic = DDS_RETCODE_ERROR;
static dds_entity_t g_response_topic = DDS_RETCODE_ERROR;
static dds_entity_t g_writer = DDS_RETCODE_ERROR;
static dds_entity_t g_reader = DDS_RETCODE_ERROR;

/** 把CycloneDDS错误码转换为Java异常，使Flutter能够显示具体失败原因。 */
static void throw_state(JNIEnv *env, const char *operation, dds_return_t code) {
  char message[256];
  snprintf(message, sizeof(message), "%s失败: %s (%d)", operation,
           dds_strretcode(-code), code);
  LOGE("%s", message);
  jclass exception = (*env)->FindClass(env, "java/lang/IllegalStateException");
  if (exception != NULL) {
    (*env)->ThrowNew(env, exception, message);
  }
}

/** 抛出不带DDS错误码的状态异常。 */
static void throw_message(JNIEnv *env, const char *message) {
  LOGE("%s", message);
  jclass exception = (*env)->FindClass(env, "java/lang/IllegalStateException");
  if (exception != NULL) {
    (*env)->ThrowNew(env, exception, message);
  }
}

/** 判断实体句柄是否创建成功。 */
static bool entity_valid(dds_entity_t entity) { return entity >= 0; }

/** 关闭参与者及其子实体，并清除当前DDS会话。调用方必须持有g_lock。 */
static void close_locked(void) {
  if (entity_valid(g_participant)) {
    dds_delete(g_participant);
  }
  if (entity_valid(g_domain)) {
    dds_delete(g_domain);
  }
  g_domain = DDS_RETCODE_ERROR;
  g_participant = DDS_RETCODE_ERROR;
  g_request_topic = DDS_RETCODE_ERROR;
  g_response_topic = DDS_RETCODE_ERROR;
  g_writer = DDS_RETCODE_ERROR;
  g_reader = DDS_RETCODE_ERROR;
}

/** 仅允许Android网卡名称中常见的安全字符，避免其进入XML配置。 */
static bool valid_interface_name(const char *name) {
  if (name == NULL || name[0] == '\0') {
    return false;
  }
  for (const char *cursor = name; *cursor != '\0'; ++cursor) {
    if (!(isalnum((unsigned char)*cursor) || *cursor == '_' || *cursor == '-' ||
          *cursor == '.')) {
      return false;
    }
  }
  return true;
}

/** 返回单调时钟纳秒值，格式与官方SDK的请求identity.id一致。 */
static int64_t monotonic_id(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return ((int64_t)now.tv_sec * 1000000000LL) + now.tv_nsec;
}

/** 等待Sport服务订阅请求Topic，避免DDS尚未发现机器人时丢掉首包。 */
static bool wait_for_sport_match(int timeout_ms) {
  const int interval_ms = 50;
  int elapsed_ms = 0;
  while (elapsed_ms <= timeout_ms) {
    dds_publication_matched_status_t status;
    memset(&status, 0, sizeof(status));
    if (dds_get_publication_matched_status(g_writer, &status) == DDS_RETCODE_OK &&
        status.current_count > 0) {
      return true;
    }
    struct timespec delay = {.tv_sec = 0, .tv_nsec = interval_ms * 1000000L};
    nanosleep(&delay, NULL);
    elapsed_ms += interval_ms;
  }
  return false;
}

/**
 * 发送一条Go2 Sport RPC请求。
 *
 * reply_data由本方法通过dds_strdup分配，调用者负责dds_free。调用方必须持有
 * g_lock，保证请求与响应按identity严格串行匹配。
 */
static int32_t call_locked(int64_t api_id, const char *parameter, bool no_reply,
                           int timeout_ms, char **reply_data) {
  if (!entity_valid(g_writer) || !entity_valid(g_reader)) {
    return 3102;
  }

  unitree_api_msg_dds__Request_ request;
  memset(&request, 0, sizeof(request));
  request.header.identity.id = monotonic_id();
  request.header.identity.api_id = api_id;
  request.header.lease.id = 0;
  request.header.policy.priority = 0;
  request.header.policy.noreply = no_reply;
  request.parameter = (char *)(parameter == NULL ? "{}" : parameter);

  dds_return_t result = dds_write(g_writer, &request);
  if (result != DDS_RETCODE_OK) {
    return 3102;
  }
  if (no_reply) {
    return 0;
  }

  const int interval_ms = 10;
  int elapsed_ms = 0;
  while (elapsed_ms <= timeout_ms) {
    void *samples[1] = {NULL};
    dds_sample_info_t infos[1];
    const dds_return_t count = dds_take(g_reader, samples, infos, 1, 1);
    if (count < 0) {
      return 3001;
    }
    if (count == 1) {
      unitree_api_msg_dds__Response_ *response =
          (unitree_api_msg_dds__Response_ *)samples[0];
      if (infos[0].valid_data &&
          response->header.identity.id == request.header.identity.id &&
          response->header.identity.api_id == api_id) {
        const int32_t code = response->header.status.code;
        if (reply_data != NULL && response->data != NULL) {
          *reply_data = dds_string_dup(response->data);
        }
        dds_return_loan(g_reader, samples, 1);
        return code;
      }
      dds_return_loan(g_reader, samples, 1);
    }
    struct timespec delay = {.tv_sec = 0, .tv_nsec = interval_ms * 1000000L};
    nanosleep(&delay, NULL);
    elapsed_ms += interval_ms;
  }
  return 3104;
}

/**
 * 初始化Android CycloneDDS、绑定指定网卡并调用只读的API版本接口。
 *
 * 成功时返回Go2 Sport服务版本；本阶段不会发送任何运动命令。
 */
JNIEXPORT jstring JNICALL
Java_com_remotecontrol_remote_dds_UnitreeDdsNative_connect(
    JNIEnv *env, jobject self, jstring interface_name) {
  (void)self;
  const char *interface_chars =
      (*env)->GetStringUTFChars(env, interface_name, NULL);
  if (interface_chars == NULL) {
    return NULL;
  }
  if (!valid_interface_name(interface_chars)) {
    (*env)->ReleaseStringUTFChars(env, interface_name, interface_chars);
    throw_message(env, "DDS网卡名称无效");
    return NULL;
  }

  pthread_mutex_lock(&g_lock);
  close_locked();

  char config[1024];
  snprintf(config, sizeof(config),
           "<CycloneDDS><Domain Id=\"any\"><General><Interfaces>"
           "<NetworkInterface name=\"%s\" priority=\"default\" "
           "multicast=\"default\"/></Interfaces></General></Domain></CycloneDDS>",
           interface_chars);
  (*env)->ReleaseStringUTFChars(env, interface_name, interface_chars);

  g_domain = dds_create_domain(0, config);
  if (!entity_valid(g_domain)) {
    const dds_return_t error = g_domain;
    close_locked();
    pthread_mutex_unlock(&g_lock);
    throw_state(env, "创建DDS Domain", error);
    return NULL;
  }
  g_participant = dds_create_participant(0, NULL, NULL);
  if (!entity_valid(g_participant)) {
    const dds_return_t error = g_participant;
    close_locked();
    pthread_mutex_unlock(&g_lock);
    throw_state(env, "创建DDS Participant", error);
    return NULL;
  }
  g_request_topic = dds_create_topic(
      g_participant, &unitree_api_msg_dds__Request__desc,
      "rt/api/sport/request", NULL, NULL);
  g_response_topic = dds_create_topic(
      g_participant, &unitree_api_msg_dds__Response__desc,
      "rt/api/sport/response", NULL, NULL);
  if (!entity_valid(g_request_topic) || !entity_valid(g_response_topic)) {
    close_locked();
    pthread_mutex_unlock(&g_lock);
    throw_message(env, "创建Go2 Sport Topic失败");
    return NULL;
  }
  g_writer = dds_create_writer(g_participant, g_request_topic, NULL, NULL);
  g_reader = dds_create_reader(g_participant, g_response_topic, NULL, NULL);
  if (!entity_valid(g_writer) || !entity_valid(g_reader)) {
    close_locked();
    pthread_mutex_unlock(&g_lock);
    throw_message(env, "创建Go2 Sport读写端点失败");
    return NULL;
  }

  if (!wait_for_sport_match(4000)) {
    close_locked();
    pthread_mutex_unlock(&g_lock);
    throw_message(env, "未发现Go2 Sport DDS服务，请检查网卡、机器人电源和组播网络");
    return NULL;
  }

  char *version = NULL;
  const int32_t code = call_locked(1, "{}", false, 2500, &version);
  if (code != 0) {
    close_locked();
    pthread_mutex_unlock(&g_lock);
    char message[160];
    snprintf(message, sizeof(message), "Go2 Sport版本检查失败，返回码=%d", code);
    throw_message(env, message);
    return NULL;
  }
  jstring result = (*env)->NewStringUTF(env, version == NULL ? "unknown" : version);
  if (version != NULL) {
    dds_free(version);
  }
  LOGI("Go2 Sport DDS connected");
  pthread_mutex_unlock(&g_lock);
  return result;
}

/** 发送已通过Flutter安全路由校验的Sport API调用并返回服务数据。 */
JNIEXPORT jstring JNICALL
Java_com_remotecontrol_remote_dds_UnitreeDdsNative_call(
    JNIEnv *env, jobject self, jlong api_id, jstring parameter,
    jboolean no_reply, jint timeout_ms) {
  (void)self;
  const char *parameter_chars =
      (*env)->GetStringUTFChars(env, parameter, NULL);
  if (parameter_chars == NULL) {
    return NULL;
  }

  pthread_mutex_lock(&g_lock);
  char *data = NULL;
  const int32_t code = call_locked((int64_t)api_id, parameter_chars,
                                   no_reply == JNI_TRUE, timeout_ms, &data);
  (*env)->ReleaseStringUTFChars(env, parameter, parameter_chars);
  if (code != 0) {
    pthread_mutex_unlock(&g_lock);
    char message[160];
    snprintf(message, sizeof(message), "Go2 Sport API %lld执行失败，返回码=%d",
             (long long)api_id, code);
    throw_message(env, message);
    return NULL;
  }
  jstring result = (*env)->NewStringUTF(env, data == NULL ? "" : data);
  if (data != NULL) {
    dds_free(data);
  }
  pthread_mutex_unlock(&g_lock);
  return result;
}

/** 释放Android DDS参与者和所有Topic、Reader、Writer资源。 */
JNIEXPORT void JNICALL
Java_com_remotecontrol_remote_dds_UnitreeDdsNative_close(JNIEnv *env,
                                                         jobject self) {
  (void)env;
  (void)self;
  pthread_mutex_lock(&g_lock);
  close_locked();
  pthread_mutex_unlock(&g_lock);
  LOGI("Go2 Sport DDS closed");
}
