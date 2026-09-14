const names={firefox:'Intent-Firefox.zip',chrome:'Intent-Chrome.zip',both:'Intent-Both.zip'};
export function kitForRelease(release, choice){
 if(!names[choice]||!release||release.draft||!Array.isArray(release.assets)) return null;
 const beta=release.tag_name==='intent-beta-feed' && release.prerelease===true;
 if(release.prerelease&&!beta) return null;
 if(!release.assets.some(a=>a.name===(beta?'appcast.xml':'release-manifest.json'))) return null;
 const filename=beta?'Intent-Tester-Mac.zip':names[choice];
 const asset=release.assets.find(a=>a.name===filename);
 if(!asset) return null;
 try{const url=new URL(asset.browser_download_url);const prefix='/logx8x-ui/intent-cli/releases/download/';
 if(url.protocol!=='https:'||url.hostname!=='github.com'||!url.pathname.startsWith(prefix)||url.username||url.password||decodeURIComponent(url.pathname.split('/').at(-1))!==filename)return null;
 return {url:url.href,version:beta?'Current beta':release.tag_name};}catch{return null;}
}
