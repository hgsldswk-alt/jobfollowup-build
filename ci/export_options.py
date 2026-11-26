"""Render signing options for the app and both extensions."""
import os
from pathlib import Path
import plistlib
import sys

data = plistlib.loads(Path(__file__).with_name("ExportOptions.plist").read_bytes())
data["teamID"] = os.environ["TEAM_ID"]
app_id = os.environ.get("APP_ID", "com.hgsldswk.jobfollowup")
data["provisioningProfiles"] = {
    app_id: os.environ.get("APP_PROFILE", "JobFollowUp AppStore"),
    app_id + ".widget": os.environ.get("WIDGET_PROFILE", "JobFollowUp Widget AppStore"),
    app_id + ".share": os.environ.get("SHARE_PROFILE", "JobFollowUp Share AppStore"),
}
sys.stdout.buffer.write(plistlib.dumps(data))
