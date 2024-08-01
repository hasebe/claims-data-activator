"""
Copyright 2022 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""
import time

from fastapi import APIRouter, Request
import base64
import firebase_admin
import os
from firebase_admin import credentials, firestore
import time
import json
from fastapi import status, Response
from config import PROCESS_TASK_URL, API_DOMAIN
from common.config import STATUS_SUCCESS
from common.utils.iap import send_iap_request
from common.utils.logging_handler import Logger

logger = Logger.get_logger(__name__)

PROJECT_ID = os.environ.get("PROJECT_ID")

# Initializing Firebase client.
firebase_admin.initialize_app(credentials.ApplicationDefault(), {
    "projectId": PROJECT_ID,
})
db = firestore.client()

router = APIRouter(prefix="/queue", tags=["Queue"])


@router.post("/publish")
async def publish_msg(request: Request, response: Response):
  logger.info(f"queue - start")

  body = await request.body()
  if not body or body == "":
    response.status_code = status.HTTP_400_BAD_REQUEST
    response.body = "Request has no body"
    logger.error(response.body)
    return response

  try:
    envelope = await request.json()
    logger.info(f"Pub/Sub envelope: {envelope}")

  except json.JSONDecodeError:
    response.status_code = status.HTTP_400_BAD_REQUEST
    response.body = f"Unable to parse to JSON: {body}"
    return response

  if not envelope:
    response.status_code = status.HTTP_400_BAD_REQUEST
    response.body = "No Pub/Sub message received"
    logger.error(f"error: {response.body}")
    return response

  if not isinstance(envelope, dict) or "message" not in envelope:
    response.status_code = status.HTTP_400_BAD_REQUEST
    response.body = "invalid Pub/Sub message format"
    logger.error(f"error: {response.body}")
    return response

  # if batch_quota_ready(): # TODO this is not working
  if True:
    pubsub_message = envelope["message"]
    # if doc_count < int(os.environ["BATCH_PROCESS_QUOTA"]):
    logger.info(f"queue - Pub/Sub message: {pubsub_message}")

    if isinstance(pubsub_message, dict) and "data" in pubsub_message:
      msg_data = base64.b64decode(
          pubsub_message["data"]).decode("utf-8").strip()
      name = json.loads(msg_data)
      payload = name.get("message_list")
      request_body = {"configs": payload}
      logger.info(f"queue - Pub/Sub message configs: {request_body}")
      # Sample request body
      # {
      #   "configs": [
      #     {
      #       "case_id": "6075e034-2763-11ed-8345-aa81c3a89f04",
      #       "uid": "jcdQmUqUKrcs8GGsmojp",
      #       "gcs_url": "gs://sample-project-dev-document-upload/6075e034-2763-11ed-8345-aa81c3a89f04/jcdQmUqUKrcs8GGsmojp/arizona-application-form.pdf",
      #       "context": "arizona"
      #     }
      #   ]
      # }

      start_time = time.time()
      print(f"queue - Sending {len(name.get('message_list'))} data to {PROCESS_TASK_URL}:")
      print(request_body)

      process_task_response = send_iap_request(PROCESS_TASK_URL, method="POST", json=request_body)

      process_time = time.time() - start_time
      time_elapsed = round(process_time * 1000)
      print(f"queue - Response from {PROCESS_TASK_URL}, Time elapsed: {str(time_elapsed)} ms")

      print(f"queue - response={process_task_response.text} with status code={process_task_response.status_code}")

      response.status_code = process_task_response.status_code
      return response
  else:
    print(f"Timeout while waiting for batch Quota to become available: {response.body}")
    response.body = "Message not acknowledged"
    response.status_code = status.HTTP_400_BAD_REQUEST
    return response

  # No Content
  return "", status.HTTP_204_NO_CONTENT


# BATCH_PROCESS_QUOTA = int(os.environ.get("BATCH_PROCESS_QUOTA", 5))
# print(f"BATCH_PROCESS_QUOTA={BATCH_PROCESS_QUOTA}")


# def check_batch_quota():
#   doc_count = get_count()
#   print(f"check_batch_quota doc_count={doc_count}")
#
#   if doc_count > BATCH_PROCESS_QUOTA:
#     print(f"check_batch_quota UNAVAILABLE")
#     return False
#   print(f"check_batch_quota AVAILABLE")
#   return True


# def batch_quota_ready(timeout=4000, period=10):
#   time_end = time.time() + timeout
#   while time.time() < time_end:
#     if check_batch_quota():
#       return True
#     print(f"Waiting for quota to become available for {period} seconds before re-checking")
#     time.sleep(period)
#   return False


def get_count():
  ct = 0
  docs = db.collection(u"document").stream()
  for doc in docs:
    a = doc.to_dict()
    #print(a)
    #print("loop")
    b = a["system_status"]
    if type(b) == list:
      #print("in loop")
      for i in b:
        l = len(b)
        if l == 1:
          #print("loop")
          if i["stage"] == "uploaded" and i["status"] == STATUS_SUCCESS:
            ct = ct + 1

  return ct
