#!/usr/bin/python3
import os, sys, json, zipfile, plistlib, tempfile, shutil, subprocess, re, stat, hashlib, signal, errno
import urllib.request, urllib.parse
from pathlib import Path, PurePosixPath

COMMON = {'cmcc_cn','unicom_cn','chinatelecom_usim_cn','cbn_cn'}
TARGETS = {'cmcc_cn':'中国移动','unicom_cn':'中国联通','chinatelecom_usim_cn':'中国电信','cbn_cn':'中国广电','hutchison_hk':'Hutchison HK','webbing':'Webbing'}
work = None
mounts = []
items = []
warnings = []
firmware_family = None
firmware_meta = None

def event(kind, **kw):
    print(json.dumps(dict(type=kind, **kw), ensure_ascii=False), flush=True)

def run(args):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def errtext(r):
    return (r.stderr or r.stdout).decode('utf-8', 'replace').strip()[-1200:]

def attached_devices():
    # If an image was manually ejected, do not treat a second detach as failure.
    result=run(['/usr/bin/hdiutil','info','-plist'])
    if result.returncode: return None
    try:
        info=plistlib.loads(result.stdout)
        return {e.get('dev-entry') for image in info.get('images',[]) for e in image.get('system-entities',[]) if e.get('dev-entry')}
    except Exception:
        return None

def cleanup():
    global work
    failed=[]
    if mounts: event('progress',message='正在卸载系统映像并清理临时文件…')
    for mount in reversed(mounts):
        r=run(['/usr/bin/hdiutil','detach',mount,'-quiet'])
        if r.returncode:
            devices=attached_devices()
            if devices is None or mount in devices: failed.append(mount)
    mounts[:] = list(reversed(failed))
    if failed:
        return '无法卸载映像：' + ', '.join(failed) + '。临时目录已保留：' + str(work) + '。请关闭占用映像的程序或在 Finder 中推出后重试。'
    if work:
        event('progress',message='正在清理临时文件…')
        try:
            shutil.rmtree(work)
        except FileNotFoundError:
            pass
        except OSError as e:
            return '无法清理临时目录：' + str(work) + '。原因：' + str(e) + '。请检查权限和磁盘状态后重试。'
        work=None
    return ''

def stop(signum, frame):
    raise SystemExit(128 + signum)
for s in (signal.SIGTERM, signal.SIGINT): signal.signal(s,stop)

def validname(name):
    p=PurePosixPath(name)
    return bool(name) and not name.startswith('/') and '\\' not in name and all(x not in ('.','..') for x in p.parts) and '\x00' not in name

def save_direct(z):
    # Only materialize paths beneath Carrier Bundles/iPhone; no archive symlinks.
    pattern=re.compile(r'(?:^|/)Carrier Bundles/(?:iPhone|iPad)/([^/]+\.bundle)(?:/(.*))?$', re.I)
    found={}
    for info in z.infolist():
        name=info.filename
        match=pattern.search(name.rstrip('/'))
        if not match: continue
        if not validname(name): raise ValueError('压缩包包含不安全的路径：'+name)
        mode=info.external_attr >> 16
        if stat.S_ISLNK(mode):
            warnings.append('压缩包内有符号链接，出于安全考虑未直接提取：'+name)
            continue
        # Keep different parent directories distinct.
        root=name[:name.lower().find(match.group(1).lower())] + match.group(1)
        group=found.setdefault(root,[])
        group.append((info,match.group(2)))
    for n,(root, entries) in enumerate(found.items()):
        target=Path(work)/'direct'/str(n)/Path(root).name
        target.mkdir(parents=True,exist_ok=True)
        for info, rel in entries:
            if not rel or info.is_dir(): continue
            out=target.joinpath(*PurePosixPath(rel).parts)
            out.parent.mkdir(parents=True,exist_ok=True)
            with z.open(info) as src, out.open('wb') as dst: shutil.copyfileobj(src,dst,1024*1024)
        source_family='iPad' if re.search(r'Carrier Bundles/iPad/',root,re.I) else 'iPhone'
        add_bundle(target, 'IPSW 压缩包直接内容', source_family)

def add_bundle(path, source, source_family=None):
    name=path.name[:-7]
    if not name or '/' in name: return
    if any(item['path']==str(path) for item in items): return
    issues=[]; info={}; carrier={}
    for f in ('Info.plist','carrier.plist'):
        try:
            with (path/f).open('rb') as h: data=plistlib.load(h)
            if f=='Info.plist' and isinstance(data,dict): info=data
            if f=='carrier.plist' and isinstance(data,dict): carrier=data
        except Exception: issues.append(f+' 缺失或无法读取')
    value=info.get('CFBundleDeviceFamily')
    values=value if isinstance(value,list) else [value]
    families=set()
    for v in values:
        if v==1 or (isinstance(v,str) and v.lower()=='iphone'): families.add('iPhone')
        if v==2 or (isinstance(v,str) and v.lower()=='ipad'): families.add('iPad')
    family=next(iter(families)) if len(families)==1 else (firmware_family or source_family)
    candidate=carrier.get('CarrierName')
    if not isinstance(candidate,str) or not candidate.strip(): candidate=info.get('CFBundleDisplayName')
    if not isinstance(candidate,str): candidate=''
    candidate=' '.join(candidate.split())[:160]
    label=TARGETS.get(name.lower()) or candidate
    items.append(dict(id=str(len(items)),name=name,label=label,source=source,path=str(path),issue='；'.join(issues),family=family or '',selected=False))

def scan_root(root, source):
    root=Path(root)
    candidates=[]
    if root.name.lower() in ('iphone','ipad') and root.parent.name.lower()=='carrier bundles': candidates.append(root)
    if root.name.lower().endswith('.bundle'):
        family=root.parent.name if root.parent.name in ('iPhone','iPad') else None
        add_bundle(root,source,family); return
    for parent in ('System/Library/Carrier Bundles','Library/Carrier Bundles','Carrier Bundles',''):
        for family in ('iPhone','iPad'):
            p=root/parent/family
            if p.is_dir() and (parent or root.name.lower()=='carrier bundles'): candidates.append(p)
    if not candidates:
        for current, dirs, files in os.walk(root, followlinks=False):
            depth=len(Path(current).relative_to(root).parts)
            if depth >= 7: dirs[:]=[]
            if Path(current).name.lower() in ('iphone','ipad') and Path(current).parent.name.lower()=='carrier bundles':
                candidates.append(Path(current)); dirs[:]=[]
            dirs[:]=[d for d in dirs if not d.endswith('.bundle') and not os.path.islink(os.path.join(current,d))]
    for folder in dict.fromkeys(candidates):
        family='iPad' if folder.name.lower()=='ipad' else 'iPhone'
        for p in sorted(folder.iterdir(),key=lambda x:x.name.lower()):
            if p.name.lower().endswith('.bundle') and p.is_dir(): add_bundle(p,source+'：'+str(folder),family)

def attach_image(path, source):
    event('progress',message='正在以只读方式挂载系统映像：'+Path(path).name)
    r=run(['/usr/bin/hdiutil','attach',str(path),'-readonly','-nobrowse','-noverify','-plist'])
    if r.returncode:
        warnings.append('无法挂载映像 '+Path(path).name+'：'+errtext(r)); return
    try: result=plistlib.loads(r.stdout)
    except Exception: raise ValueError('无法解析磁盘映像挂载结果，可能需要手动在 Finder 中推出映像。')
    entities=result.get('system-entities',[])
    points=[e['mount-point'] for e in entities if 'mount-point' in e]
    # Detach the image as a whole by its outer device, including unmounted APFS containers.
    dev=next((e.get('dev-entry') for e in entities if e.get('dev-entry')),None)
    if dev: mounts.append(dev)
    elif points: mounts.append(points[0])
    if not points:
        warnings.append('映像已打开但没有可读取的卷：'+Path(path).name); return
    for point in points: scan_root(point,source)

def inspect_firmware(path):
    p=Path(path)
    if not p.is_file() or p.suffix.lower()!='.ipsw': raise ValueError('请选择完整的 IPSW 固件文件。')
    try:
        with zipfile.ZipFile(p) as z:
            entry=z.getinfo('BuildManifest.plist')
            if entry.file_size>64*1024*1024: raise ValueError('固件清单大小异常。')
            manifest=plistlib.loads(z.read(entry))
    except KeyError: raise ValueError('固件缺少 BuildManifest.plist，无法确认机型和版本。')
    except zipfile.BadZipFile: raise ValueError('无法读取固件：文件不完整或不是有效的 IPSW。')
    types=manifest.get('SupportedProductTypes',[])
    if not isinstance(types,list): types=[]
    types=sorted(set(x for x in types if isinstance(x,str) and re.fullmatch(r'(iPhone|iPad)\d+,\d+',x)),key=str.lower)
    all_types=manifest.get('SupportedProductTypes',[])
    if not types and all_types: raise ValueError('此固件不是已识别的 iPhone 或 iPad 固件。')
    kinds=sorted(set('iPhone' if x.startswith('iPhone') else 'iPad' for x in types))
    table_path=Path(__file__).resolve().parent/'devices.json'
    try: names=json.loads(table_path.read_text(encoding='utf-8'))
    except Exception: names={}
    models=[{'id':x,'name':names.get(x,'')} for x in types]
    return {'path':str(p),'version':str(manifest.get('ProductVersion') or '未提供'),
            'build':str(manifest.get('ProductBuildVersion') or '未提供'),
            'models':models,'family':kinds[0] if len(kinds)==1 else '',
            'firmware_type': ' / '.join(kinds) if kinds else '未能识别'}

def manifest_images(z):
    try:
        manifest=plistlib.loads(z.read('BuildManifest.plist'))
        paths=[]
        identities=manifest.get('BuildIdentities',[])
        normal=[i for i in identities if not str(i.get('Info',{}).get('Variant','')).lower().startswith('recovery')]
        for ident in normal or identities:
            m=ident.get('Manifest',{})
            # OS is the root filesystem; avoid extracting unrelated restore images.
            p=m.get('OS',{}).get('Info',{}).get('Path')
            if isinstance(p,str) and p in z.namelist() and p not in paths: paths.append(p)
        return paths
    except Exception: return []

class AppleRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_apple_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)

def check_apple_url(url):
    parts=urllib.parse.urlsplit(url)
    host=(parts.hostname or '').lower()
    allowed=(host == 'apple.com' or host.endswith('.apple.com') or host == 'fcs-keys-pub-prod.cdn-apple.com')
    if parts.scheme != 'https' or not allowed or parts.username or parts.password or parts.port not in (None,443):
        raise ValueError('固件中的密钥地址不是有效的 Apple HTTPS 地址。')

def get_aea_key(z, name):
    with z.open(name) as f:
        header=f.read(12)
        if len(header)!=12 or header[:4]!=b'AEA1' or int.from_bytes(header[4:7],'little')!=1:
            raise ValueError('不支持的 AEA 映像格式或加密方式。')
        size=int.from_bytes(header[8:12],'little')
        if size<4 or size>1024*1024: raise ValueError('AEA 元数据长度异常。')
        blob=f.read(size)
        if len(blob)!=size: raise ValueError('AEA 元数据不完整。')
    fields={}
    while blob:
        if len(blob)<4: raise ValueError('AEA 元数据不完整。')
        size=int.from_bytes(blob[:4],'little')
        if size<5 or size>len(blob): raise ValueError('AEA 元数据格式异常。')
        field=blob[4:size].split(b'\x00',1)
        if len(field)!=2: raise ValueError('AEA 元数据格式异常。')
        fields[field[0].decode('utf-8')]=field[1].decode('utf-8')
        blob=blob[size:]
    url=fields.get('com.apple.wkms.fcs-key-url','')
    check_apple_url(url)
    response=json.loads(fields['com.apple.wkms.fcs-response'])
    event('progress',message='正在从 Apple 密钥服务获取解密资料（需要网络）…')
    opener=urllib.request.build_opener(AppleRedirect())
    with opener.open(url,timeout=30) as result:
        pem=result.read(8193)
    if len(pem)>8192: raise ValueError('Apple 返回的密钥数据异常。')
    helper=Path(__file__).resolve().parent/'aea-key'
    # Source-tree tests locate the helper in the neighboring application bundle.
    if not helper.exists(): helper=Path(__file__).resolve().parents[1]/'IPCC提取工具.app/Contents/Resources/aea-key'
    if not helper.is_file(): raise ValueError('未找到 AEA 解密组件；需要 macOS 14 或更新版本。')
    payload=json.dumps({'pem':pem.decode('utf-8'),'enc':response['enc-request'],'wrapped':response['wrapped-key']}).encode()
    p=subprocess.run([str(helper)],input=payload,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode or len(p.stdout)!=32: raise ValueError('无法解析 AEA 密钥：'+errtext(p))
    return p.stdout

def extract_aea(z, name, index):
    key=get_aea_key(z,name)
    encrypted=Path(work)/('image-'+str(index)+'.dmg.aea')
    image=Path(work)/('image-'+str(index)+'.dmg')
    keypath=Path(work)/('image-'+str(index)+'.key')
    try:
        event('progress',message='正在解压加密系统映像（可能需要数分钟及较大临时空间）：'+Path(name).name)
        with z.open(name) as src, encrypted.open('wb') as dst: shutil.copyfileobj(src,dst,1024*1024)
        fd=os.open(str(keypath),os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
        with os.fdopen(fd,'wb') as f: f.write(key)
        event('progress',message='正在解密系统映像，可能需要数分钟…')
        r=run(['/usr/bin/aea','decrypt','-i',str(encrypted),'-o',str(image),'-key',str(keypath)])
        if r.returncode: raise ValueError('系统映像解密失败：'+errtext(r))
        encrypted.unlink()
        return image
    finally:
        keypath.unlink(missing_ok=True)

def scan(path):
    global work, items, warnings, firmware_family, firmware_meta
    firmware_family = None
    cleanup_warning=cleanup() if work else ''
    if cleanup_warning: raise RuntimeError(cleanup_warning)
    work=tempfile.mkdtemp(prefix='IPCCExtractor-'); items=[]; warnings=[]; firmware_meta=None
    p=Path(path)
    if not p.exists(): raise ValueError('所选文件或文件夹不存在。')
    event('progress',message='正在检查所选内容…')
    if p.is_dir(): scan_root(p,'所选文件夹')
    elif p.name.lower().endswith('.dmg'): attach_image(p,'所选映像')
    elif p.name.lower().endswith('.ipsw'):
        meta=inspect_firmware(str(p)); firmware_family=meta['family'] or None; firmware_meta=meta
        with zipfile.ZipFile(p) as z:
            event('progress',message='正在扫描 IPSW 中可直接读取的运营商配置…')
            save_direct(z)
            images=manifest_images(z)
            if not images:
                choices=[i for i in z.infolist() if i.filename.lower().endswith(('.dmg','.dmg.aea')) and not any(s in i.filename.lower() for s in ('ramdisk','restore','cryptex'))]
                choices.sort(key=lambda i:i.file_size, reverse=True)
                images=[choices[0].filename] if choices else []
                if images: warnings.append('未能从清单确定系统映像，已尝试体积最大的候选映像；其他映像未扫描。')
            if not images and not items: warnings.append('未找到系统映像；该 IPSW 的布局可能不受支持。')
            for index, name in enumerate(images):
                if not validname(name): warnings.append('跳过不安全的映像路径：'+name); continue
                if name.lower().endswith('.aea'):
                    try:
                        image=extract_aea(z,name,index)
                        attach_image(image,'IPSW 系统映像 '+Path(name).name)
                    except Exception as e:
                        warnings.append('无法读取 AEA 系统映像 '+name+'：'+str(e)+'。可尝试选择已解密的 DMG 或已提取的文件夹。')
                    continue
                event('progress', message='正在从 IPSW 解压系统映像（可能需要较长时间和数 GB 空间）：'+Path(name).name)
                image=Path(work)/('image-'+str(index)+'.dmg')
                with z.open(name) as src, image.open('wb') as dst: shutil.copyfileobj(src,dst,1024*1024)
                attach_image(image,'IPSW 系统映像 '+Path(name).name)
    else: raise ValueError('请选择 .ipsw、已解密的 .dmg 或已提取的文件夹。')
    event('result',items=items,warnings=warnings)

def safe_files(bundle):
    base=bundle.resolve(strict=True)
    output=[]
    def visit(directory, rel, stack):
        resolved=directory.resolve(strict=True)
        if os.path.commonpath([str(base),str(resolved)]) != str(base): raise ValueError('包含指向配置包外部的链接：'+str(directory))
        if resolved in stack: raise ValueError('配置包包含循环链接：'+str(directory))
        for p in sorted(directory.iterdir(),key=lambda x:x.name):
            resolved_p=p.resolve(strict=True)
            if os.path.commonpath([str(base),str(resolved_p)]) != str(base): raise ValueError('包含指向配置包外部的链接：'+str(p))
            child=rel / p.name
            if p.is_dir(): visit(p,child,stack | {resolved})
            elif p.is_file(): output.append((p,child))
            else: raise ValueError('包含不支持的特殊文件：'+str(p))
    visit(bundle,Path(),set())
    return output

def export_folder_name(meta):
    if not meta: return 'IPCC_Export'
    version=meta.get('version',''); build=meta.get('build',''); family=meta.get('family','')
    if not isinstance(version,str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,3}',version): return 'IPCC_Export'
    if not isinstance(build,str) or not re.fullmatch(r'[A-Za-z0-9._-]{1,40}',build): return 'IPCC_Export'
    if family not in ('iPhone','iPad'): return 'IPCC_Export'
    major=int(version.split('.')[0])
    prefix='iPadOS' if family=='iPad' and major>=13 else 'iOS'
    return prefix+'_'+version+'('+build+')_ipcc'

def export(ids, folder, grouped=False):
    out=Path(folder)
    if not out.is_dir(): raise ValueError('导出位置不是有效文件夹。')
    selected=[i for i in items if i['id'] in ids]
    if not selected: raise ValueError('请先勾选运营商。')
    if grouped:
        folder_name=export_folder_name(firmware_meta)
        target=out/folder_name; number=2
        while True:
            try: target.mkdir(); out=target; break
            except FileExistsError: target=out/(folder_name+' ('+str(number)+')'); number+=1
    successes=[]; errors=[]
    for idx,item in enumerate(selected):
        event('progress',message='正在导出 '+str(idx+1)+' / '+str(len(selected))+'：'+item['name'])
        tmp=None
        try:
            if item['issue']: raise ValueError(item['issue'])
            name=item['name']
            if not re.fullmatch(r'[A-Za-z0-9_.-]+',name) or name in ('.','..'): raise ValueError('配置包名称包含不支持的字符。')
            bundle=Path(item['path']); files=safe_files(bundle)
            if not files: raise ValueError('配置包为空。')
            suffix='_'+item['family'] if item.get('family') in ('iPhone','iPad') else ''
            target=out/(name+suffix+'.ipcc'); number=2
            while target.exists(): target=out/(name+suffix+'_'+str(number)+'.ipcc'); number+=1
            fd,tmp=tempfile.mkstemp(prefix='.ipcc-',suffix='.tmp',dir=str(out)); os.close(fd)
            hashes={}
            with zipfile.ZipFile(tmp,'w',zipfile.ZIP_DEFLATED,allowZip64=True) as z:
                for file,rel in files:
                    arc='Payload/'+bundle.name+'/'+rel.as_posix()
                    z.write(file,arc)
                    h=hashlib.sha256()
                    with file.open('rb') as f:
                        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
                    hashes[arc]=h.digest()
            with zipfile.ZipFile(tmp) as z:
                bad=z.testzip()
                if bad: raise ValueError('压缩包校验失败：'+bad)
                for arc,digest in hashes.items():
                    if hashlib.sha256(z.read(arc)).digest()!=digest: raise ValueError('导出内容与原文件不一致：'+arc)
                for plist in ('Info.plist','carrier.plist'): plistlib.loads(z.read('Payload/'+bundle.name+'/'+plist))
            # Exclusive publish avoids overwriting an existing user file.
            while True:
                try:
                    try:
                        os.link(tmp,target)
                    except OSError as link_error:
                        if link_error.errno not in (errno.EPERM, errno.ENOTSUP, errno.EXDEV, errno.EOPNOTSUPP): raise
                        # Some external and network volumes do not support hard links.
                        with open(target,'xb') as dest:
                            try:
                                with open(tmp,'rb') as source: shutil.copyfileobj(source,dest,1024*1024)
                            except BaseException:
                                dest.close()
                                os.unlink(target)
                                raise
                    break
                except FileExistsError:
                    target=out/(name+suffix+'_'+str(number)+'.ipcc'); number+=1
            os.unlink(tmp); tmp=None
            successes.append(str(target))
        except Exception as e: errors.append(item['name']+'：'+str(e))
        finally:
            if tmp and os.path.exists(tmp): os.unlink(tmp)
    event('exported',files=successes,errors=errors,folder=str(out))

try:
    for line in sys.stdin:
        try:
            cmd=json.loads(line); action=cmd.get('action')
            if action=='inspect': event('firmware_info',**inspect_firmware(cmd['path']))
            elif action=='scan': scan(cmd['path'])
            elif action=='export': export(cmd['ids'],cmd['folder'],cmd.get('grouped',False))
            elif action=='cleanup':
                message=cleanup()
                event('cleanup_result',ok=not bool(message),message=message)
            elif action=='quit': break
            else: raise ValueError('未知操作。')
        except Exception as e: event('error',message=str(e) or type(e).__name__)
finally:
    try:
        message=cleanup()
        if message: event('warning',message=message)
    except Exception:
        pass
