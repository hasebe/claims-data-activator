import datetime
import json
import os
import traceback
import uuid
import time
import requests
from config import DOCUMENT_STATUS_URL
from fastapi import APIRouter
from fastapi import HTTPException
from fastapi import Request
from fastapi import Response
from fastapi import status
from fastapi.concurrency import run_in_threadpool
from google.cloud import storage
from common.utils.logging_handler import Logger
from common.config import BUCKET_NAME
from common.config import START_PIPELINE_FILENAME
from common.config import STATUS_ERROR
from common.config import STATUS_SUCCESS
from common.models import Document
from common.utils.copy_gcs_documents import copy_blob
from common.utils.helper import split_uri_2_path_filename
from common.utils.iap import send_iap_request
from common.utils.publisher import publish_document

logger = Logger.get_logger(__name__)

# API clients
gcs = None

MIME_TYPES = [
    "application/pdf",
    # "image/gif",  # TODO Add Support for all these types
    # "image/tiff",
    # "image/jpeg",
    # "image/png",
    # "image/bmp",
    # "image/webp"
]


def generate_case_id(folder_name):
  # generate a case_id
  dirs_string = folder_name.replace("/", "_")
  uuid_str = str(uuid.uuid1())
  ll = max(len(str(dirs_string)), int(len(uuid_str)/2))
  case_id = str(dirs_string) + "_" + str(uuid.uuid1())[:-ll]
  return case_id


router = APIRouter(prefix="/start-pipeline", tags=["Start Pipeline"])


@router.post("/run")
async def start_pipeline(request: Request, response: Response):
  start_time = time.time()

  body = await request.body()
  if not body or body == "":
    response.status_code = status.HTTP_400_BAD_REQUEST
    response.body = "Request has no body"
    logger.warning(response.body)
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

  if not isinstance(envelope,
                    dict) or "bucket" not in envelope or "name" not in envelope:
    response.status_code = status.HTTP_400_BAD_REQUEST
    response.body = "invalid Pub/Sub message format"
    logger.error(f"error: {response.body}")
    return response

  bucket_name = envelope['bucket']
  file_uri = envelope['name']
  logger.info(f"start_pipeline bucket_name={bucket_name}, file_uri={file_uri}")
  comment = ""
  context = "california"  # TODO is a temp workaround

  try:
    event_id = datetime.datetime.utcnow().strftime('%Y-%m-%d-%H-%M-%S')
    dirs, filename = split_uri_2_path_filename(file_uri)

    logger.info(
        f"Received event event_id={event_id} for bucket[{bucket_name}] file_uri=[{file_uri}], filename=[{filename}]")

    if filename != START_PIPELINE_FILENAME:
      logger.info(f"Skipping action, since waiting for {START_PIPELINE_FILENAME} to trigger pipe-line")
      return "", status.HTTP_204_NO_CONTENT

    logger.info(
        f"start_pipeline - Starting pipeline to process documents inside {bucket_name} bucket and "
        f"{dirs} folder with event_id={event_id}")

    global gcs
    if not gcs:
      gcs = storage.Client()

    # Get List of Document Objects from the Output Bucket
    if dirs is None or dirs == "":
      blob_list = gcs.list_blobs(bucket_name)
    else:
      blob_list = gcs.list_blobs(bucket_name, prefix=dirs + "/")
    uid_list = []
    message_list = []

    case_ids = {}
    try:
      # Browse through output Forms and identify matching Processor for each Form
      count = 0

      for blob in blob_list:
        logger.debug(f"Handling {blob.name}")
        if blob.name and not blob.name.endswith('/') and blob.name != START_PIPELINE_FILENAME:
          mime_type = blob.content_type
          if mime_type not in MIME_TYPES:
            logger.info(f"Skipping {blob.name} - not supported mime type: {mime_type} ")
            continue
          d, blob_filename = split_uri_2_path_filename(blob.name)
          dir_name = os.path.split(d)[-1]
          if dir_name not in case_ids.keys():
            case_id = generate_case_id(dir_name)
            case_ids[dir_name] = case_id
          else:
            case_id = case_ids[dir_name]
          count = count + 1
          logger.info(
              f"start_pipeline - Handling {count}(th) document - case_id={case_id}, file_path={blob.name}, "
              f"file_name={blob_filename}, event_id={event_id}")

          # create a record in database for uploaded document
          output = create_document(case_id, blob.name, context)
          uid = output
          if uid is None:
            logger.error(f"Error: could not create a document")
            raise HTTPException(
                status_code=500,
                detail="Error "
                       "in uploading document in gcs bucket")

          logger.info(f"Created document with uid={uid} for case_id={case_id}, "
                      f"file_path={blob.name}, file_name={blob_filename}, "
                      f"event_id={event_id}")
          uid_list.append(uid)

          # Copy document in GCS bucket
          new_file_name = f"{case_id}/{uid}/{blob_filename}"
          result = await run_in_threadpool(copy_blob, bucket_name, blob.name, new_file_name, BUCKET_NAME)
          if result != STATUS_SUCCESS:
            # Update the document upload in GCS as failed
            document = Document.find_by_uid(uid)
            system_status = {
                "stage": "upload",
                "status": STATUS_ERROR,
                "timestamp": datetime.datetime.utcnow(),
                "comment": comment
            }
            document.system_status = [system_status]
            document.update()
            logger.error(f"Error: {result}")
            raise HTTPException(
                status_code=500,
                detail="Error "
                       "in uploading document in gcs bucket")

          logger.info(f"File {blob.name} with case_id {case_id} and uid {uid}"
                      f" uploaded successfully in GCS bucket")

          # Update the document upload as success in DB
          document = Document.find_by_uid(uid)
          if document is not None:
            gcs_base_url = f"gs://{BUCKET_NAME}"
            document.url = f"{gcs_base_url}/{case_id}/{uid}/{blob_filename}"
            system_status = {
                "stage": "uploaded",
                "status": STATUS_SUCCESS,
                "timestamp": datetime.datetime.utcnow(),
                "comment": comment
            }
            document.system_status = [system_status]
            document.update()
            message_list.append({
                "case_id": case_id,
                "uid": uid,
                "gcs_url": document.url,
                "context": context
            })
          else:
            logger.error(f"Could not retrieve document by id {uid}")

      logger.info(f"start_pipeline - Uploaded {count} documents and"
                  f" sending {len(message_list)} items in message_list")
      # Pushing Message To Pubsub
      pubsub_msg = f"batch moved to bucket"
      message_dict = {"message": pubsub_msg, "message_list": message_list}
      publish_document(message_dict)

      process_time = time.time() - start_time
      time_elapsed = round(process_time * 1000)
      logger.info(f"start_pipeline - completed within {time_elapsed} ms for event_id {event_id} with {count} documents "
                  f"{message_list}")

      return {
          "status": f"Files for event_id {event_id} uploaded"
                    f"successfully, the document"
                    f" will be processed in sometime ",
          "event_id": event_id,
          "uid_list": uid_list,
          "configs": message_list
      }

    except Exception as e:
      logger.error(e)
      err = traceback.format_exc().replace("\n", " ")
      logger.error(err)
      raise HTTPException(
          status_code=500, detail="Error "
                                  "in uploading document") from e

  except HTTPException as e:
    raise e
  except Exception as e:
    logger.error(e)
    err = traceback.format_exc().replace("\n", " ")
    logger.error(err)
    raise HTTPException(
        status_code=500, detail="Error "
                                "in uploading document") from e


def create_document(case_id, filename, context, user=None):
  uid = None
  try:
    logger.info(f"create_document with case_id = {case_id} filename = {filename} context = {context}")
    base_url = f"{DOCUMENT_STATUS_URL}"
    req_url = f"{base_url}/create_document"
    url = f"{req_url}?case_id={case_id}&filename={filename}&context={context}&user={user}"
    logger.info(f"Posting request to {url}")
    response = send_iap_request(url, method="POST")
    response = response.json()
    logger.info(f"Response received ={response}")
    uid = response.get("uid")
  except requests.exceptions.RequestException as err:
    logger.error(err)

  return uid
