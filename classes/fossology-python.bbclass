# This class integrates real-time license scanning, generation of SPDX standard
# output and verifiying license info during the building process.
# It is a combination of efforts from the OE-Core, SPDX and fossology projects.
#
# For more information on fossology REST API:
#   https://www.fossology.org/get-started/basic-rest-api-calls/
#
# For more information on SPDX:
#   http://www.spdx.org
#
# Note:
# 1) Make sure fossology (after 3.5.0)(https://hub.docker.com/r/fossology/fossology/) has beed started on your host
# 2) spdx files will be output to the path which is defined as[SPDX_DEPLOY_DIR].
#    By default, SPDX_DEPLOY_DIR is tmp/deploy/
# 3) Added TOKEN has been set in conf/local.conf
#
COPYLEFT_RECIPE_TYPES ?= 'target nativesdk'
inherit copyleft_filter

inherit spdx-common 

do_upload[dirs] = "${SPDX_TOPDIR}"
do_schedule_jobs[dirs] = "${SPDX_TOPDIR}"
do_get_report[dirs] = "${SPDX_OUTDIR}"

#CREATOR_TOOL = "fossology-python.bbclass in meta-spdxscanner"
FOSSOLOGY_SERVER ?= "http://127.0.0.1/repo"
WAIT_TIME ?= "20"

python () {
    from multiprocessing import Lock

    global create_folder_lock 

    create_folder_lock = Lock()

    #If not for target, won't creat spdx.
    if bb.data.inherits_class('nopackages', d):
        return

    pn = d.getVar('PN')
    assume_provided = (d.getVar("ASSUME_PROVIDED") or "").split()
    if pn in assume_provided:
        for p in d.getVar("PROVIDES").split():
            if p != pn:
                pn = p
                break

    # glibc-locale: do_fetch, do_unpack and do_patch tasks have been deleted,
    # so avoid archiving source here.
    if pn.startswith('glibc-locale'):
        return
    if (d.getVar('PN') == "libtool-cross"):
        return
    if (d.getVar('PN') == "libgcc-initial"):
        return
    if (d.getVar('PN') == "shadow-sysroot"):
        return

    # We just archive gcc-source for all the gcc related recipes
    if d.getVar('BPN') in ['gcc', 'libgcc']:
        bb.debug(1, 'spdx: There is bug in scan of %s is, do nothing' % pn)
        return

    spdx_outdir = d.getVar('SPDX_OUTDIR')
    spdx_workdir = d.getVar('SPDX_WORKDIR')
    spdx_temp_dir = os.path.join(spdx_workdir, "temp")
    temp_dir = os.path.join(d.getVar('WORKDIR'), "temp")

    info = {}
    info['workdir'] = (d.getVar('WORKDIR') or "")
    info['pn'] = (d.getVar( 'PN') or "")
    info['pv'] = (d.getVar( 'PV') or "")

    manifest_dir = (d.getVar('SPDX_DEPLOY_DIR') or "")
    if not os.path.exists( manifest_dir ):
        bb.utils.mkdirhier( manifest_dir )

    info['outfile'] = os.path.join(manifest_dir, info['pn'] + "-" + info['pv'] + ".spdx" )
    sstatefile = os.path.join(spdx_outdir, info['pn'] + "-" + info['pv'] + ".spdx" )
    if os.path.exists(info['outfile']):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        return
    if os.path.exists( sstatefile ):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        create_manifest(info,sstatefile)
        return

    def hasTask(task):
        return bool(d.getVarFlag(task, "task", False)) and not bool(d.getVarFlag(task, "noexec", False))
    
    if d.getVarFlag('ARCHIVER_MODE', 'srpm') == "1" and d.getVar('PACKAGES'):
        # Some recipes do not have any packaging tasks
        if hasTask("do_package_write_rpm") or hasTask("do_package_write_ipk") or hasTask("do_package_write_deb"):
            d.appendVarFlag('do_schedule_jobs', 'depends', ' %s:do_upload' % pn)
            d.appendVarFlag('do_get_report', 'depends', ' %s:do_schedule_jobs' % pn)
            d.appendVarFlag('do_spdx', 'depends', ' %s:do_get_report' % pn)
            bb.build.addtask('do_upload', 'do_configure', 'do_patch', d)
            bb.build.addtask('do_schedule_jobs', 'do_configure', 'do_upload', d)
            bb.build.addtask('do_get_report', 'do_configure', 'do_schedule_jobs', d)
            bb.build.addtask('do_spdx', 'do_configure', 'do_get_report', d)
}

python do_upload(){
    import logging, shutil,time

    if bb.data.inherits_class('nopackages', d):
        return

    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    logging.basicConfig(level=logging.INFO)

    from fossology import Fossology, fossology_token
    from fossology.obj import TokenScope
    from fossology.exceptions import FossologyApiError, AuthenticationError
    from tenacity import retry, TryAgain, stop_after_attempt


    info = {}
    info['workdir'] = (d.getVar('WORKDIR') or "")
    info['pn'] = (d.getVar( 'PN') or "")
    info['pv'] = (d.getVar( 'PV') or "")

    manifest_dir = (d.getVar('SPDX_DEPLOY_DIR') or "")
    if not os.path.exists( manifest_dir ):
        bb.utils.mkdirhier( manifest_dir )

    spdx_outdir = d.getVar('SPDX_OUTDIR')
    info['outfile'] = os.path.join(manifest_dir, info['pn'] + "-" + info['pv'] + ".spdx" )
    sstatefile = os.path.join(spdx_outdir, info['pn'] + "-" + info['pv'] + ".spdx" )
    if os.path.exists(info['outfile']):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        return
    if os.path.exists( sstatefile ):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        create_manifest(info,sstatefile)
        return

    fossology_server = d.getVar('FOSSOLOGY_SERVER')
    token = d.getVar('TOKEN')
    foss = Fossology(fossology_server, token, "fossy")

    spdx_workdir = d.getVar('SPDX_WORKDIR')
    spdx_temp_dir = os.path.join(spdx_workdir, "temp")
    temp_dir = os.path.join(d.getVar('WORKDIR'), "temp")
    bb.utils.mkdirhier(spdx_workdir)

    spdx_get_src(d)

    if os.path.isdir(spdx_temp_dir):
        for f_dir, f in list_files(spdx_temp_dir):
            temp_file = os.path.join(spdx_temp_dir,f_dir,f)
            shutil.copy(temp_file, temp_dir)

    tar_file = spdx_create_tarball(d, d.getVar('WORKDIR'), 'patched', spdx_outdir)

    d.setVar('WORKDIR', spdx_workdir)

    if d.getVar('FOLDER_NAME', False):
        folder_name = d.getVar('FOLDER_NAME')
        folder = create_folder(d, foss, token, folder_name)
        time.sleep(int(d.getVar('WAIT_TIME')))
        bb.note("folder = " + folder.name)
    else:
        folder = foss.rootFolder
    
    bb.note("Begin to upload.")
    upload = get_upload(d, folder, foss)
    if upload == None:
        upload = upload_oss(d, folder, foss, tar_file)
        time.sleep(int(d.getVar('WAIT_TIME')))
    else:
        pn = (d.getVar( 'PN') or "")
        bb.warn(pn + "has already been uploaded, don't upload again.")
}
def get_upload(d, folder, foss):
    filename = get_upload_file_name(d)
    upload_list,pages = foss.list_uploads()
    upload = None
    bb.note("Check tarball, %s ,has been uploaded?" % filename)
    for upload in upload_list:
        bb.note("upload  = %s" % upload)
        if upload.uploadname == filename and upload.foldername == folder.name:
            bb.note("The size of uploaded file is %s" % upload.filesize)
            bb.note("Found " + upload.uploadname  + " in " + folder.name)
            bb.note("filesha1  = %s" % upload.filesha1)
            return upload
    return None

def upload_oss(d, folder, foss, filepath):
    import os

    from fossology.exceptions import AuthorizationError, FossologyApiError
    from tenacity import TryAgain
    from fossology.obj import AccessLevel

    (work_dir, filename) = os.path.split(filepath)

    upload_list = foss.list_uploads()
    upload = None
    bb.note("Begin to upload..." + filename)
    try:
        upload = foss.upload_file(
        folder,
        file=filepath,
        access_level=AccessLevel.PUBLIC,
        group=None,
        wait_time=120
        )
    except AttributeError as error:
        bb.error(error.message)
    except FossologyApiError as error:
        bb.error(error.message)
    except TryAgain:
        time.sleep(30)

    return upload

def get_upload_file_name(d):
    tarname = get_tar_name(d, 'patched')
    bb.note("get_upload_file_name :" + tarname)
    return tarname
 
def create_folder(d, foss, token, folder_name):
    exist = 0

    folder_list = foss.list_folders()
    for folder in folder_list:
        if folder.name == folder_name:
            exist = 1
            break

    if exist == 0:
        bb.note("create_folder :")
        create_folder_lock.acquire()
        folder = foss.create_folder(foss.rootFolder, folder_name, description=None)
        create_folder_lock.release()
        if folder.name != folder_name:
            bb.error("Folder %s couldn't be created" % folder_name)
    else:
        return folder

python do_schedule_jobs(){
    import os
    import re
    import time
    import logging

    #If not for target, won't creat spdx.
    if bb.data.inherits_class('nopackages', d):
        return

    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    logging.basicConfig(level=logging.INFO)

    from fossology import Fossology, fossology_token
    from fossology.obj import TokenScope
    from fossology.exceptions import FossologyApiError, AuthenticationError
    from tenacity import retry, TryAgain, stop_after_attempt
    from fossology.obj import Agents

    bb.note("Begin to schedule jobs!")
    info = {}
    info['workdir'] = (d.getVar('WORKDIR') or "")
    info['pn'] = (d.getVar( 'PN') or "")
    info['pv'] = (d.getVar( 'PV') or "")

    manifest_dir = (d.getVar('SPDX_DEPLOY_DIR') or "")
    if not os.path.exists( manifest_dir ):
        bb.utils.mkdirhier( manifest_dir )

    spdx_outdir = d.getVar('SPDX_OUTDIR')
    info['outfile'] = os.path.join(manifest_dir, info['pn'] + "-" + info['pv'] + ".spdx" )
    sstatefile = os.path.join(spdx_outdir, info['pn'] + "-" + info['pv'] + ".spdx" )
    if os.path.exists(info['outfile']):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        return
    if os.path.exists( sstatefile ):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        create_manifest(info,sstatefile)
        return

    fossology_server = d.getVar('FOSSOLOGY_SERVER')
    token = d.getVar('TOKEN')
    foss = Fossology(fossology_server, token, "fossy")
    pn = d.getVar('PN')

    if d.getVar('FOLDER_NAME', False):
        folder_name = d.getVar('FOLDER_NAME')
        folder = create_folder(d, foss, token, folder_name)
    else:
        folder = foss.rootFolder

    upload = get_upload(d, folder, foss)
    if upload == None:
        bb.error("%s has not been uploaded." + pn)

    if not foss.user.agents:
        additional_agent = {"PokyAgent": True}
        foss.user.agents = Agents(True, True, False, False, True, True, True, True, True,)
    analysis_agents = foss.user.agents.to_dict()
    jobs_spec = {
        "analysis": analysis_agents,
        "decider": {
            "nomos_monk": True,
            "bulk_reused": True,
            "new_scanner": True,
            "ojo_decider": True,
        },
        "reuse": {
            "reuse_upload": 0,
            "reuse_group": 0,
            "reuse_main": True,
            "reuse_enhanced": True,
        },
    }

    jobs,pages = foss.list_jobs(upload=upload)
    if jobs == None:
        try:
            job = foss.schedule_jobs(folder, upload, jobs_spec)
            if job.name != upload.uploadname:
                bb.error("Job %s does not relate to the correct upload" % job.name )
        except FossologyApiError as error:
            bb.error(error.message)
    elif len(jobs) < 2:
        try:
            job = foss.schedule_jobs(folder, upload, jobs_spec)
            if job.name != upload.uploadname:
                bb.error("Job %s does not relate to the correct upload" % job.name )
        except FossologyApiError as error:
            bb.error(error.message)
    else:
        bb.note("%s jobs has existed " % len(jobs))

    time.sleep(int(d.getVar('WAIT_TIME')))
    bb.note("Schedule jobs is end!")
}

def check_jobs(d, foss, uploaded):
    i = 0
    job_wait = 120
    time_wait = 30

    while i < 20:
        i += 1
        try:
            jobs,pages = foss.list_jobs(upload=uploaded)
        except FossologyApiError as error:
            bb.error(error.message)

        bb.note("jobs[0].uploadId = %s" % jobs[0].uploadId)
        if len(jobs) < 2:
            if i == 4:
                bb.error("%s jobs start is still not completed." % uploaded.uploadname)
            else:
                bb.warn("%s jobs start not completed " % uploaded.uploadname)
            time.sleep(time_wait)
        else:
            break

    i = 0
    while i < 5:
        i += 1
        job = foss.detail_job(jobs[1].id, wait=True, timeout=job_wait)
        if job.status != "Completed":
            bb.warn("The Job is still not completed yet. Please comfirm your fossology server.")
            time.sleep(time_wait)
        else:
            bb.note("jobs has completed.")
            return job
    bb.error("The Job is still not completed yet. Please comfirm your fossology server.")

python do_get_report(){

    import os, sys, json, shutil, time
    import logging
    import subprocess
    from fossology import Fossology, fossology_token
    from fossology.exceptions import AuthorizationError, FossologyApiError
    from tenacity import TryAgain
    from fossology.obj import ReportFormat

    i = 0
    wait_time = 60
    complete = False
    report_id = None
    report = None

    #If not for target, won't creat spdx.
    if bb.data.inherits_class('nopackages', d):
        return

    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    logging.basicConfig(level=logging.INFO)

    bb.note("Begin to get report!")

    fossology_server = d.getVar('FOSSOLOGY_SERVER')
    token = d.getVar('TOKEN')
    foss = Fossology(fossology_server, token, "fossy")
    pn = d.getVar('PN')

    if d.getVar('FOLDER_NAME', False):
        folder_name = d.getVar('FOLDER_NAME')
        folder = create_folder(d, foss, token, folder_name)
    else:
        folder = foss.rootFolder
    
    manifest_dir = (d.getVar('SPDX_DEPLOY_DIR') or "")
    if not os.path.exists( manifest_dir ):
        bb.utils.mkdirhier( manifest_dir )

    spdx_workdir = d.getVar('SPDX_WORKDIR')
    temp_dir = os.path.join(d.getVar('WORKDIR'), "temp")
    spdx_temp_dir = os.path.join(spdx_workdir, "temp")
    spdx_outdir = d.getVar('SPDX_OUTDIR')

    cur_ver_code = get_ver_code(spdx_workdir).split()[0]

    info = {}
    info['workdir'] = (d.getVar('WORKDIR') or "")
    info['pn'] = (d.getVar( 'PN') or "")
    info['pv'] = (d.getVar( 'PV') or "")
    info['package_download_location'] = (d.getVar( 'SRC_URI') or "")
    if info['package_download_location'] != "":
        info['package_download_location'] = info['package_download_location'].split()[0]
    info['spdx_version'] = (d.getVar('SPDX_VERSION') or '')

    info['outfile'] = os.path.join(manifest_dir, info['pn'] + "-" + info['pv'] + ".spdx" )
    spdx_file = os.path.join(spdx_outdir, info['pn'] + "-" + info['pv'] + ".spdx" )
    if os.path.exists(info['outfile']):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        return
    if os.path.exists( spdx_file ):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        create_manifest(info,spdx_file)
        return

    info['data_license'] = (d.getVar('DATA_LICENSE') or '')
    info['creator'] = {}
    info['creator']['Tool'] = (d.getVar('CREATOR_TOOL') or '')
    info['license_list_version'] = (d.getVar('LICENSELISTVERSION') or '')
    info['package_homepage'] = (d.getVar('HOMEPAGE') or "")
    info['package_summary'] = (d.getVar('SUMMARY') or "")
    info['package_summary'] = info['package_summary'].replace("\n","")
    info['package_summary'] = info['package_summary'].replace("'"," ")
    info['package_contains'] = (d.getVar('CONTAINED') or "")
    info['package_static_link'] = (d.getVar('STATIC_LINK') or "")
    info['modified'] = "false"
    srcuri = d.getVar("SRC_URI", False).split()
    length = len("file://")
    for item in srcuri:
        if item.startswith("file://"):
            item = item[length:]
            if item.endswith(".patch") or item.endswith(".diff"):
                info['modified'] = "true"

    upload = get_upload(d, folder, foss)
    if upload == None:
        bb.error("Has not been uploaded.")
    check_jobs(d, foss, upload)
    try:
        report_id = foss.generate_report(
            upload, report_format=ReportFormat.SPDX2TV
        )
    except FossologyApiError as error:
        bb.error(error.message)
    except AuthorizationError as error:
        bb.error(error.message)
    except AttributeError as error:
        bb.error("AttributeError! It seems fossology server is busy.")
    if report_id == None:
        bb.error("Get report id failed! Maybe fossology server is busy.")
        return
    while i < 20:
        i += 1
        bb.note("Begin to download_report. report_id = " + report_id)
        try:
            report = foss.download_report(report_id)
        except TryAgain:
            bb.warn("SPDX file is still not ready, try again.")
            time.sleep(wait_time)
            continue
        except FossologyApiError as error:
            bb.warn("Dowload SPDX file failed, Try again.")
            continue
        if report == None:
            bb.error("Fail to download report.")
            break

    report = str(report).lstrip("('")
    report = report.rstrip("')")
    with open(spdx_file, "w+") as file:
        file.write(report)
    file.close()
    
    subprocess.call(r"sed -i -e 's#\\n#\n#g' %s" % spdx_file, shell=True)

    if bb.data.inherits_class('packagegroup',d):
        return True
    if bb.data.inherits_class('image',d):
        return True
    if bb.data.inherits_class('packagegroup',d):
        return True
    if bb.data.inherits_class('image',d):
        return True

    file = open(spdx_file,'r+')
    line = file.readline()
    while line:
        if "LicenseID:" in line:
            complete = True
            break
        line = file.readline()
    file.close()

    write_cached_spdx(info,spdx_file,cur_ver_code)
    create_manifest(info,spdx_file)
    if complete == False:
        bb.warn("license info not complete, please confirm.")
    else:
        time.sleep(int(d.getVar('WAIT_TIME')))
        return True
}

SSTATETASKS += "do_spdx"
python do_spdx_setscene () {
    sstate_setscene(d)
}
addtask do_spdx_setscene
do_spdx () {
    echo "Create spdx file."
}
#addtask do_upload
#addtask do_upload after do_patch
#addtask do_schedule_jobs after do_upload
#addtask do_get_report after do_schedule_jobs
#addtask do_spdx before do_configure after do_patch
#addtask do_spdx before do_configure after do_patch
addtask do_upload after do_patch
addtask do_schedule_jobs after do_upload
addtask do_get_report after do_schedule_jobs
addtask do_spdx
do_build[recrdeptask] += "do_spdx"
do_populate_sdk[recrdeptask] += "do_spdx"

