const names={firefox:'Intent-Firefox.zip',chrome:'Intent-Chrome.zip',both:'Intent-Both.zip'};
export function kitForRelease(release, choice){
 if(!names[choice]||!release||release.draft||release.prerelease||!Array.isArray(release.assets)) return null;
 if(!release.assets.some(a=>a.name==='release-manifest.json')) return null;
 const asset=release.assets.find(a=>a.name===names[choice]);
 if(!asset) return null;
 try{const url=new URL(asset.browser_download_url);const prefix='/logx8x-ui/intent-cli/releases/download/';
 if(url.protocol!=='https:'||url.hostname!=='github.com'||!url.pathname.startsWith(prefix)||url.username||url.password||decodeURIComponent(url.pathname.split('/').at(-1))!==names[choice])return null;
 return {url:url.href,version:release.tag_name};}catch{return null;}
}
