"""
Copyright 2024 Google LLC

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

""" Document status endpoints """
import datetime
import traceback
from typing import Dict
from typing import List
from typing import Optional

import fireo
from fastapi import APIRouter
from fastapi import HTTPException

from common.config import BUCKET_NAME
from common.config import STATUS_ERROR
from common.config import STATUS_SPLIT
from common.config import STATUS_SUCCESS
from common.config import get_display_name_by_doc_class
from common.models import Document
from common.utils.logging_handler import Logger


logger = Logger.get_logger(__name__)
# disabling for linting to pass
# pylint: disable = broad-except

router = APIRouter()


@router.post("/create_document")
async def create_document(case_id: str, filename: str, context: str, user=None):
  """takes case_id ,filename as input and Save the record in the database

     Args:
       case_id (str): Case id of the files
       filename : get the filename form upload files api
       context: The context for which application is being used
                Example - Arizona , Callifornia etc
     Returns:
       200 : PDF files are successfully saved in db
       500 : If something fails
     """
  try:
    logger.info(f"create_document with case_id={case_id}, filename={filename}, context={context}")
    document = Document()
    document.case_id = case_id
    document.upload_timestamp = datetime.datetime.utcnow()
    document.context = context
    document.uid = document.save().id
    document.active = "active"
    document.system_status = [{
        "is_hitl": True if user else False,
        "user": "User" if user else None,
        "stage": "upload",
        "status": STATUS_SUCCESS,
        "timestamp": datetime.datetime.utcnow()
    }]
    document.save()
    return {"status": STATUS_SUCCESS, "status_code": 200, "uid": document.uid}

  except Exception as e:
    logger.error(f"Error in create document for case_id {case_id} "
                 f"and {filename}")
    logger.error(e)
    err = traceback.format_exc().replace("\n", " ")
    logger.error(err)
    raise HTTPException(
        status_code=500,
        detail=f"Error in creating documents for case_id {case_id}") from e


@router.post("/update_classification_status")
async def update_classification_status(
    case_id: str,
    uid: str,
    status: str,
    is_hitl: Optional[bool] = False,
    document_class: Optional[str] = None,
    classification_score: Optional[float] = None,
):
  """takes case_id , uid , document_class  ,status of
        classification service as input
        updates the document class
        ,status in database
     Args:
       case_id (str): Case id of the files
       filename : get the filename form upload files api
       context: The context for which application is being used
                Example - Arizona , Callifornia etc
     Returns:
       200 : PDF files are successfully saved in db
       500 :Internal Server Error if something fails
       """
  try:
    document = Document.find_by_uid(uid)
    if status in [STATUS_SUCCESS, STATUS_SPLIT]:
      #update document class
      document.document_class = document_class
      document.classification_score = classification_score
      document.document_display_name = get_display_name_by_doc_class(document_class)
      document.is_hitl_classified = is_hitl
      system_status = {
          "is_hitl": is_hitl,
          "stage": "classification",
          "status": status,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.update()

    return {
        "status": STATUS_SUCCESS,
        "status_code": 200,
        "case_id": case_id,
        "uid": uid
    }

  except Exception as e:
    logger.error(f"Error in updating classification status for "
                 f"case_id {case_id} and uid {uid}")
    logger.error(e)
    err = traceback.format_exc().replace("\n", " ")
    logger.error(err)
    raise HTTPException(
        status_code=500,
        detail="Error in updating classification status") from e


@router.post("/update_extraction_status")
async def update_extraction_status(case_id: str,
                                   uid: str,
                                   status: str,
                                   entity: Optional[List[Dict]] = None,
                                   extraction_score: Optional[float] = None,
                                   extraction_status: Optional[str] = None):
  """takes case_id , uid , extraction_score ,status
    of classification service as input
    updates the document class, status in database

         Args:
           case_id (str): Case id of the files
           uid (str): uid for document
           entity_list: list of dictionary for extracted entity
           extraction_score: average extraction score return by parser
           status : status of extraction service
         Returns:
           200 : Database updated successfully
           """
  try:
    document = Document.find_by_uid(uid)
    if status == STATUS_SUCCESS:
      system_status = {
          "stage": "extraction",
          "status": STATUS_SUCCESS,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.entities = entity
      document.extraction_score = extraction_score
      document.extraction_status = extraction_status
      document.update()
    else:
      system_status = {
          "stage": "extraction",
          "status": STATUS_ERROR,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.update()
    return {
        "status": STATUS_SUCCESS,
        "status_code": 200,
        "case_id": case_id,
        "uid": uid
    }

  except Exception as e:
    logger.error(f"Error in updating extraction status case_id {case_id} "
                 f"and uid {uid}")
    logger.error(e)
    err = traceback.format_exc().replace("\n", " ")
    logger.error(err)
    raise HTTPException(
        status_code=500, detail="Error in updating"
        " extraction status") from e


@router.post("/update_validation_status")
async def update_validation_status(case_id: str,
                                   uid: str,
                                   status: str,
                                   entities: Optional[List[Dict]] = None,
                                   validation_score: Optional[float] = None):
  """takes case_id , uid , validation status of validation
  service as input and updates in database

         Args:
           case_id (str): Case id of the files
           uid (str): uid for document
           validation_score:  validation score return
           status : status of validation service
         Returns:
           200 : Database updated successfully
           505 : If something fails
          """
  try:
    document = Document.find_by_uid(uid)
    if status == STATUS_SUCCESS:
      document.validation_score = validation_score
      document.entities = entities
      system_status = {
          "stage": "validation",
          "status": STATUS_SUCCESS,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.update()
    else:
      system_status = {
          "stage": "validation",
          "status": STATUS_ERROR,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.update()

    return {
        "status": STATUS_SUCCESS,
        "status_code": 200,
        "case_id": case_id,
        "uid": uid
    }

  except Exception as e:
    logger.error(f"Error in updating validation status"
                 f" for case_id {case_id} and uid {uid}")
    logger.error(e)
    err = traceback.format_exc().replace("\n", " ")
    logger.error(err)
    raise HTTPException(
        status_code=500, detail="Error in updating"
        " validation status") from e


@router.post("/update_matching_status")
async def update_matching_status(case_id: str,
                                 uid: str,
                                 status: str,
                                 entity: Optional[List[dict]] = None,
                                 matching_score: Optional[float] = None):
  """takes case_id , uid , entity,
  status  of matching service as input and updates in database

             Args:
               case_id (str): Case id of the files
               uid (str): uid for document
               matching_score:  matching score return
               status : status of validation service
             Returns:
               200 : Database updated successfully
               404 :Document not found
               505 : If something fails
           """
  try:
    document = Document.find_by_uid(uid)
    if status == STATUS_SUCCESS:
      system_status = {
          "stage": "matching",
          "status": STATUS_SUCCESS,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.update()
      document.matching_score = matching_score
      document.entities = entity
      document.save()
    else:
      system_status = {
          "stage": "matching",
          "status": STATUS_ERROR,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.update()

    return {
        "status": STATUS_SUCCESS,
        "status_code": 200,
        "case_id": case_id,
        "uid": uid
    }

  except Exception as e:
    logger.error(f"Error in updating matching status for"
                 f" case_id {case_id} and uid {uid}")
    logger.error(e)
    err = traceback.format_exc().replace("\n", " ")
    logger.error(err)
    raise HTTPException(
        status_code=500, detail="Error in updating matching status") from e


@router.post("/update_autoapproved_status")
async def update_autoapproved(case_id: str, uid: str, status: str,
                              autoapproved_status: str, is_autoapproved: str):
  try:
    document = Document.find_by_uid(uid)
    if status == STATUS_SUCCESS:
      document.auto_approval = autoapproved_status
      system_status = {
          "stage": "auto_approval",
          "status": STATUS_SUCCESS,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.is_autoapproved = is_autoapproved
      document.update()
    else:
      system_status = {
          "stage": "auto_approval",
          "status": STATUS_ERROR,
          "timestamp": datetime.datetime.utcnow()
      }
      document.system_status = fireo.ListUnion([system_status])
      document.update()
    return {"status": STATUS_SUCCESS, "case_id": case_id, "uid": uid}
  except Exception as e:
    err = traceback.format_exc().replace("\n", " ")
    logger.error(err)
    raise HTTPException(
        status_code=500, detail="Error in "
        "updating the autoapproval status") from e


@router.post("/create_documet_json_input")
async def create_documet_json_input(case_id: str, document_class: str, entity: List[dict],
                                    context: str):
  """takes case_id , uid , entity, status  of matching
   service as input and updates in database

  Args:
   case_id (str): Case id of the files
   uid (str): uid for document
   matching_score:  matching score return
   status : status of validation service
  Returns:
   200 : Database updated successfully """
  try:
    document = Document()
    document.case_id = case_id
    document.entities = entity
    document.upload_timestamp = datetime.datetime.utcnow()
    system_status = {
        "stage": "uploaded",
        "status": STATUS_SUCCESS,
        "timestamp": datetime.datetime.utcnow()
    }
    document.system_status = fireo.ListUnion([system_status])
    document.active = "active"
    document.document_class = document_class
    document.context = context
    document.uid = document.save().id
    gcs_base_url = f"gs://{BUCKET_NAME}"
    document.url = f"{gcs_base_url}/{case_id}/{document.uid}" \
                f"/input_data_{case_id}_{document.uid}.json"
    document.save()
    return {"status": STATUS_SUCCESS, "uid": document.uid}

  except Exception as e:
    logger.error("Error in  creating document")
    logger.error(e)
    err = traceback.format_exc().replace("\n", " ")
    logger.error(err)
    raise HTTPException(
        status_code=500, detail="Error in"
        " creating the document") from e
