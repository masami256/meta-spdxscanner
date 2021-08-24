# This class integrates real-time license scanning, generation of SPDX standard
# output and verifiying license info during the building process.
# It is a combination of efforts from the OE-Core, SPDX and DoSOCSv2 projects.
#
# For more information on DoSOCSv2:
#   https://github.com/DoSOCSv2
#
# For more information on SPDX:
#   http://www.spdx.org
#
# Note:
# 1) Make sure fossdriver has beed installed in your host
# 2) By default,spdx files will be output to the path which is defined as[SPDX_DEPLOY_DIR] 
#    in ./meta/conf/spdx-dosocs.conf.


SPDXEPENDENCY += "${PATCHTOOL}-native:do_populate_sysroot"
SPDXEPENDENCY += " wget-native:do_populate_sysroot"
SPDXEPENDENCY += " subversion-native:do_populate_sysroot"
SPDXEPENDENCY += " git-native:do_populate_sysroot"
SPDXEPENDENCY += " lz4-native:do_populate_sysroot"
SPDXEPENDENCY += " lzip-native:do_populate_sysroot"
SPDXEPENDENCY += " xz-native:do_populate_sysroot"
SPDXEPENDENCY += " unzip-native:do_populate_sysroot"
SPDXEPENDENCY += " xz-native:do_populate_sysroot"
SPDXEPENDENCY += " nodejs-native:do_populate_sysroot"
SPDXEPENDENCY += " quilt-native:do_populate_sysroot"
SPDXEPENDENCY += " tar-native:do_populate_sysroot"

SPDX_TOPDIR ?= "${WORKDIR}/spdx_sstate_dir"
SPDX_OUTDIR = "${SPDX_TOPDIR}/${TARGET_SYS}/${PF}/"
SPDX_WORKDIR = "${WORKDIR}/spdx_temp/"

do_spdx[dirs] = "${WORKDIR}"

LICENSELISTVERSION = "2.6"
CREATOR_TOOL = "meta-spdxscanner"

# If ${S} isn't actually the top-level source directory, set SPDX_S to point at
# the real top-level directory.
SPDX_S ?= "${S}"

python do_spdx () {
    import os, sys, json, shutil

    orig_WORKDIR = d.getVar('WORKDIR')
    orig_S = d.getVar('S')
    orig_B = d.getVar('B')
    d.setVar('ORIG_S', orig_S)

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
    if (d.getVar('BPN') == "linux-yocto"):
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
    info['workdir'] = (d.getVar('WORKDIR', True) or "")
    info['pn'] = (d.getVar( 'PN', True ) or "")
    info['pv'] = (d.getVar( 'PV', True ) or "")
    info['package_download_location'] = (d.getVar( 'SRC_URI', True ) or "")
    if info['package_download_location'] != "":
        info['package_download_location'] = info['package_download_location'].split()[0]
    info['spdx_version'] = (d.getVar('SPDX_VERSION', True) or '')
    info['data_license'] = (d.getVar('DATA_LICENSE', True) or '')
    info['creator'] = {}
    info['creator']['Tool'] = (d.getVar('CREATOR_TOOL', True) or '')
    info['license_list_version'] = (d.getVar('LICENSELISTVERSION', True) or '')
    info['package_homepage'] = (d.getVar('HOMEPAGE', True) or "")
    info['package_summary'] = (d.getVar('SUMMARY', True) or "")
    info['package_summary'] = info['package_summary'].replace("\n","")
    info['package_summary'] = info['package_summary'].replace("'"," ")
    info['package_contains'] = (d.getVar('CONTAINED', True) or "")
    info['package_static_link'] = (d.getVar('STATIC_LINK', True) or "")
    info['modified'] = "False"
    srcuri = d.getVar("SRC_URI", False).split()
    length = len("file://")
    for item in srcuri:
        if item.startswith("file://"):
            item = item[length:]
            if item.endswith(".patch") or item.endswith(".diff"):
                info['modified'] = "True"

    manifest_dir = (d.getVar('SPDX_DEPLOY_DIR', True) or "")
    info['outfile'] = os.path.join(manifest_dir, info['pn'] + "-" + info['pv'] + ".spdx" )
    sstatefile = os.path.join(spdx_outdir, info['pn'] + "-" + info['pv'] + ".spdx" )
    
    # if spdx has been exist
    if os.path.exists(info['outfile']):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
    #    return
    if os.path.exists( sstatefile ):
        bb.note(info['pn'] + "spdx file has been exist, do nothing")
        create_manifest(info,sstatefile)
        return

    if d.getVar('DPN') == "":
        spdx_get_src(d)
    else:
        spdx_get_src_metadebian(d)

    bb.note('SPDX: Archiving the patched source...')
    if os.path.isdir(spdx_temp_dir):
        for f_dir, f in list_files(spdx_temp_dir):
            temp_file = os.path.join(spdx_temp_dir,f_dir,f)
            shutil.copy(temp_file, temp_dir)
        shutil.rmtree(spdx_temp_dir)
    d.setVar('WORKDIR', spdx_workdir)
    tar_name = spdx_create_tarball(d, d.getVar('WORKDIR'), 'patched', spdx_outdir)
    ## get everything from cache.  use it to decide if 
    ## something needs to be rerun
    if not os.path.exists(spdx_outdir):
        bb.utils.mkdirhier(spdx_outdir)
    cur_ver_code = get_ver_code(spdx_workdir).split()[0] 
    ## Get spdx file
    bb.note(' run fossdriver ...... ')
    if not os.path.isfile(tar_name):
        bb.warn(info['pn'] + "has no source, do nothing")
        return
    invoke_fossdriver(tar_name,sstatefile)
    if get_cached_spdx(sstatefile) != None:
        write_cached_spdx( info,sstatefile,cur_ver_code )
        ## CREATE MANIFEST(write to outfile )
        create_manifest(info,sstatefile)
    else:
        bb.warn('Can\'t get the spdx file ' + info['pn'] + '. Please check your.')

    d.setVar('WORKDIR', orig_WORKDIR)
    d.setVar('S', orig_S)
    d.setVar('B', orig_B)
}

# To support meta-debian, don't run unpack and patch task during spdx task.
# Therefore copy patched source after patch task
addtask do_spdx before do_configure after do_patch

def spdx_create_tarball(d, srcdir, suffix, ar_outdir):
    """
    create the tarball from srcdir
    """
    import tarfile, shutil
    # Make sure we are only creating a single tarball for gcc sources
    #if (d.getVar('SRC_URI') == ""):
    #    return

    # For the kernel archive, srcdir may just be a link to the
    # work-shared location. Use os.path.realpath to make sure
    # that we archive the actual directory and not just the link.
    srcdir = os.path.realpath(srcdir)

    bb.utils.mkdirhier(ar_outdir)
    if suffix:
        filename = '%s-%s.tar.gz' % (d.getVar('PF'), suffix)
    else:
        filename = '%s.tar.gz' % d.getVar('PF')
    tarname = os.path.join(ar_outdir, filename)

    bb.note('Creating %s' % tarname)
    tar = tarfile.open(tarname, 'w:gz')
    tar.add(srcdir, arcname=os.path.basename(srcdir))
    tar.close()
    shutil.rmtree(srcdir)
    return tarname

# Run do_unpack and do_patch
def spdx_get_src(d):
    import shutil
    spdx_workdir = d.getVar('SPDX_WORKDIR')
    spdx_sysroot_native = d.getVar('STAGING_DIR_NATIVE')
    pn = d.getVar('PN')

    # We just archive gcc-source for all the gcc related recipes
    if d.getVar('BPN') in ['gcc', 'libgcc']:
        bb.debug(1, 'spdx: There is bug in scan of %s is, do nothing' % pn)
        return

    # The kernel class functions require it to be on work-shared, so we dont change WORKDIR
    if not is_work_shared(d):
        # Change the WORKDIR to make do_unpack do_patch run in another dir.
        d.setVar('WORKDIR', spdx_workdir)
        # Restore the original path to recipe's native sysroot (it's relative to WORKDIR).
        d.setVar('STAGING_DIR_NATIVE', spdx_sysroot_native)

        # The changed 'WORKDIR' also caused 'B' changed, create dir 'B' for the
        # possibly requiring of the following tasks (such as some recipes's
        # do_patch required 'B' existed).
        bb.utils.mkdirhier(d.getVar('B'))

        bb.build.exec_func('do_unpack', d)

    # Make sure gcc and kernel sources are patched only once
    if not (d.getVar('SRC_URI') == "" or is_work_shared(d)):
        bb.build.exec_func('do_patch', d)
    # Some userland has no source.
    if not os.path.exists( spdx_workdir ):
        bb.utils.mkdirhier(spdx_workdir)

def spdx_get_src_metadebian(d):
    import shutil
    spdx_workdir = d.getVar('SPDX_WORKDIR')
    spdx_sysroot_native = d.getVar('STAGING_DIR_NATIVE')
    pn = d.getVar('PN')

    # We just archive gcc-source for all the gcc related recipes
    if d.getVar('BPN') in ['gcc', 'libgcc']:
        bb.debug(1, 'spdx: There is bug in scan of %s is, do nothing' % pn)
        return

    # The kernel class functions require it to be on work-shared, so we dont change WORKDIR
    if not is_work_shared(d):
        # Change the WORKDIR to make do_unpack do_patch run in another dir.
        d.setVar('WORKDIR', spdx_workdir)
        # Restore the original path to recipe's native sysroot (it's relative to WORKDIR).
        d.setVar('STAGING_DIR_NATIVE', spdx_sysroot_native)

        # The changed 'WORKDIR' also caused 'B' changed, create dir 'B' for the
        # possibly requiring of the following tasks (such as some recipes's
        # do_patch required 'B' existed).
        bb.utils.mkdirhier(d.getVar('B'))

    # Some userland has no source.
    if not os.path.exists( spdx_workdir ):
        bb.utils.mkdirhier(spdx_workdir)

    copy_sources(d)


def copy_sources(d):
    import os

    if not is_work_shared(d):
        src_dir = d.getVar('ORIG_S')
        dst_dir = d.getVar('WORKDIR')
        cmd = 'cp -r {} {}'.format(src_dir, dst_dir)
        bb.debug(1, 'cmd : {}'.format(cmd))
        ret = os.system(cmd)


def invoke_fossdriver(tar_file, spdx_file):
    import os
    import time
    delaytime = 20
    import logging

    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
    logging.basicConfig(level=logging.INFO)

    (work_dir, tar_file) = os.path.split(tar_file)
    os.chdir(work_dir)

    from fossdriver.config import FossConfig
    from fossdriver.server import FossServer
    from fossdriver.tasks import (CreateFolder, Upload, Scanners, Copyright, Reuse, BulkTextMatch, SPDXTV)
    if 'http_proxy' in os.environ:
        del os.environ['http_proxy']
    config = FossConfig()
    configPath = os.path.join(os.path.expanduser('~'),".fossdriverrc")
    config.configure(configPath)
    server = FossServer(config)
    server.Login()
    bb.note("invoke_fossdriver : tar_file = %s " % tar_file)
    if (Reuse(server, tar_file, "Software Repository", tar_file, "Software Repository").run()  != True):
        bb.note("This OSS has not been scanned. So upload it to fossology server.")
        i = 0
        while i < 5:
            if (Upload(server, tar_file, "Software Repository").run() != True):
                bb.warn("%s Upload failed, try again!" %  tar_file)
                time.sleep(delaytime)
                i += 1
            else:
                i = 0
                while i < 10:                
                    if (Scanners(server, tar_file, "Software Repository").run() != True):
                        bb.warn("%s scanner failed, try again!" % tar_file)
                        time.sleep(delaytime)
                        i+= 1
                    else:
                        i = 0
                        while i < 10:
                            Copyright(server, tar_file, "Software Repository").run()
                            if (SPDXTV(server, tar_file, "Software Repository", spdx_file).run() == False):
                                bb.warn("%s SPDXTV failed, try again!" % tar_file)
                                time.sleep(delaytime)
                                i += 1
                            else:
                                return True
                        bb.warn("%s SPDXTV failed, Please check your fossology server." % tar_file)
                        return False
                bb.warn("%s Scanners failed, Please check your fossology server." % tar_file)
                return False
        bb.warn("%s  Upload fail.Please check your fossology server." % tar_file)
        return False
    else:
        i = 0
        while i < 10:
            if (SPDXTV(server, tar_file, "Software Repository", spdx_file).run() == False):
                time.sleep(1)
                bb.warn("%s SPDXTV failed, try again!" % tar_file)
                i += 1
                time.sleep(delaytime)
            else:
                return True
        bb.warn("%s SPDXTV failed, Please check your fossology server." % tar_file)
        return False

def create_manifest(info,sstatefile):
    import shutil
    shutil.copyfile(sstatefile,info['outfile'])

def get_cached_spdx( sstatefile ):
    import subprocess

    if not os.path.exists( sstatefile ):
        return None
    
    try:
        output = subprocess.check_output(['grep', "PackageVerificationCode", sstatefile])
    except subprocess.CalledProcessError as e:
        bb.error("Index creation command '%s' failed with return code %d:\n%s" % (e.cmd, e.returncode, e.output))
        return None
    cached_spdx_info=output.decode('utf-8').split(': ')
    return cached_spdx_info[1]

## Add necessary information into spdx file
def write_cached_spdx( info,sstatefile, ver_code ):
    import subprocess

    def sed_replace(dest_sed_cmd,key_word,replace_info):
        dest_sed_cmd = dest_sed_cmd + "-e 's#^" + key_word + ".*#" + \
            key_word + replace_info + "#' "
        return dest_sed_cmd

    def sed_insert(dest_sed_cmd,key_word,new_line):
        dest_sed_cmd = dest_sed_cmd + "-e '/^" + key_word \
            + r"/a\\" + new_line + "' "
        return dest_sed_cmd

    ## Document level information
    sed_cmd = r"sed -i -e 's#\r$##g' " 
    spdx_DocumentComment = "<text>SPDX for " + info['pn'] + " version " \ 
        + info['pv'] + "</text>"
    sed_cmd = sed_replace(sed_cmd,"DocumentComment",spdx_DocumentComment)
    
    ## Creator information
    sed_cmd = sed_replace(sed_cmd,"Creator: ",info['creator']['Tool'])

    ## Package level information
    sed_cmd = sed_replace(sed_cmd, "PackageName: ", info['pn'])
    sed_cmd = sed_insert(sed_cmd, "PackageName: ", "PackageVersion: " + info['pv'])
    sed_cmd = sed_replace(sed_cmd, "PackageDownloadLocation: ",info['package_download_location'])
    sed_cmd = sed_insert(sed_cmd, "PackageDownloadLocation: ", "PackageHomePage: " + info['package_homepage'])
    sed_cmd = sed_insert(sed_cmd, "PackageDownloadLocation: ", "PackageSummary: " + "<text>" + info['package_summary'] + "</text>")
    sed_cmd = sed_insert(sed_cmd, "PackageDownloadLocation: ", "modification record : " + info['modified'])
    sed_cmd = sed_replace(sed_cmd, "PackageVerificationCode: ",ver_code)
    sed_cmd = sed_insert(sed_cmd, "PackageVerificationCode: ", "PackageDescription: " + 
        "<text>" + info['pn'] + " version " + info['pv'] + "</text>")
    for contain in info['package_contains'].split( ):
        sed_cmd = sed_insert(sed_cmd, "PackageComment:"," \\n\\n## Relationships\\nRelationship: " + info['pn'] + " CONTAINS " + contain)
    for static_link in info['package_static_link'].split( ):
        sed_cmd = sed_insert(sed_cmd, "PackageComment:"," \\n\\n## Relationships\\nRelationship: " + info['pn'] + " STATIC_LINK " + static_link)
    sed_cmd = sed_cmd + sstatefile

    subprocess.call("%s" % sed_cmd, shell=True)

def is_work_shared(d):
    pn = d.getVar('PN')
    return bb.data.inherits_class('kernel', d) or pn.startswith('gcc-source')

def remove_dir_tree(dir_name):
    import shutil
    try:
        shutil.rmtree(dir_name)
    except:
        pass

def remove_file(file_name):
    try:
        os.remove(file_name)
    except OSError as e:
        pass

def list_files(dir ):
    for root, subFolders, files in os.walk(dir):
        for f in files:
            rel_root = os.path.relpath(root, dir)
            yield rel_root, f
    return

def hash_file(file_name):
    """
    Return the hex string representation of the SHA1 checksum of the filename
    """
    try:
        import hashlib
    except ImportError:
        return None
    
    sha1 = hashlib.sha1()
    with open( file_name, "rb" ) as f:
        for line in f:
            sha1.update(line)
    return sha1.hexdigest()

def hash_string(data):
    import hashlib
    sha1 = hashlib.sha1()
    sha1.update(data.encode('utf-8'))
    return sha1.hexdigest()

def get_ver_code(dirname):
    chksums = []
    for f_dir, f in list_files(dirname):
        try:
            stats = os.stat(os.path.join(dirname,f_dir,f))
        except OSError as e:
            bb.warn( "Stat failed" + str(e) + "\n")
            continue
        chksums.append(hash_file(os.path.join(dirname,f_dir,f)))
    ver_code_string = ''.join(chksums).lower()
    ver_code = hash_string(ver_code_string)
    return ver_code

do_spdx[depends] = "${SPDXEPENDENCY}"

EXPORT_FUNCTIONS do_spdx
