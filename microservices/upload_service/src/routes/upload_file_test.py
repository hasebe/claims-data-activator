"""
  Tests for Claim endpoints
"""
import os
# disabling pylint rules that conflict with pytest fixtures
# pylint: disable=unused-argument,redefined-outer-name,unused-import
from testing.fastapi_fixtures import client_with_emulator
from common.testing.firestore_emulator import firestore_emulator, clean_firestore
from common.models import Documentstatus
# from .config_test import  TESTDATA_FILENAME1 ,TESTDATA_FILENAME2

# assigning url
api_url = "http://localhost:8080/upload_service/v1/upload/"
os.environ["FIRESTORE_EMULATOR_HOST"] = "localhost:8080"
os.environ["GOOGLE_CLOUD_PROJECT"] = "fake-project"
SUCCESS_RESPONSE = {"status": "Success"}

TESTDATA_FILENAME1 = os.path.join(
    os.path.dirname(__file__), "..", "testing", "Arkansas-form-1.pdf")


def test_upload_file_pdf_positive(client_with_emulator):

  with open(TESTDATA_FILENAME1, "rb") as test_file:
    response = client_with_emulator.post(
        f"{api_url}upload_file",
        json={"case_id": "2321"},
        files={"file": test_file})
    print(response)
  assert response.status_code == 200, "Status 200"

