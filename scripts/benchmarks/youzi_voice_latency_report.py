"""Make a self-contained temporary HTML from output-only playback probe results.
No invented timings. WAV is synthesized PCM replay, not acoustic capture.
Usage: python youzi_voice_latency_report.py /tmp/youzi-voice-latency
"""
import base64
import io
import json
from pathlib import Path
import sys
import wave



def validate_run(run):
    """Reject invented/missing/causally impossible playback milestones."""
    events = run['events']
    def at(name, segment=None):
        found = [e['seconds'] for e in events if e['event'] == name
                 and (segment is None or e.get('segment') == segment)]
        if not found:
            raise ValueError(f'Missing {name} segment={segment}')
        return found[0]
    if not (0 <= at('llm_request') <= at('first_text') <= at('llm_done')):
        raise ValueError('Invalid LLM event ordering')
    for segment in range(1, run['sentence_count'] + 1):
        ordered = [at(n, segment) for n in ('sentence_ready', 'tts_request', 'first_pcm_byte',
                   'pcm_enqueued', 'first_nonsilent_render', 'playback_drained')]
        if ordered != sorted(ordered):
            raise ValueError(f'Invalid output/tap ordering segment={segment}')
        if run.get('tts_transport_mode') == 'buffered_legacy' and at('tts_eof', segment) > at('pcm_enqueued', segment):
            raise ValueError('Legacy buffered measurement must receive all PCM before enqueue')
        if segment > 1 and at('tts_request', segment) < at('playback_drained', segment - 1):
            raise ValueError('Probe does not follow serial sentence playback policy')


def collect(folder):
    runs = []
    for path in sorted(folder.glob('run-*/results.json')):
        run = json.loads(path.read_text())
        run['artifact'] = str(path)
        parts = []
        for pcm in sorted(path.parent.glob('sentence-*.pcm'), key=lambda p: int(p.stem.split('-')[1])):
            parts.append(pcm.read_bytes())
        if parts and run.get('status') == 'completed':
            out = io.BytesIO()
            with wave.open(out, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(24000)
                wav.writeframes(b''.join(parts))
            path.with_name('reply.wav').write_bytes(out.getvalue())
            run['audio_data_uri'] = 'data:audio/wav;base64,' + base64.b64encode(out.getvalue()).decode()
        if run.get('status') == 'completed':
            validate_run(run)
        runs.append(run)
    preload = folder / 'preload.json'
    evidence = folder / 'runtime-evidence.json'
    return {'runs': runs, 'preload': json.loads(preload.read_text()) if preload.exists() else None,
            'runtime': json.loads(evidence.read_text()) if evidence.exists() else None}


TEMPLATE = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>柚子 · 语音链路实测</title><link rel="icon" href="data:,">
<style>
:root{color-scheme:light;--ink:#192836;--muted:#596a79;--bg:#f3f6f7;--line:#dfe7ea;--blue:#3873d6;--purple:#8558c3;--green:#1e8c74;--amber:#aa651b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}main{max-width:1250px;margin:44px auto;padding:0 28px 44px}.top{display:flex;justify-content:space-between;gap:24px;align-items:flex-start}.eyebrow{color:var(--green);font-size:12px;font-weight:750;letter-spacing:.15em}h1{font-size:36px;letter-spacing:-1px;line-height:1.2;margin:12px 0}h2{font-size:18px;margin:0}p{margin:8px 0;color:var(--muted)}.badge{white-space:nowrap;color:#80581c;border:1px solid #e8d4b0;background:#fff7e8;border-radius:30px;padding:7px 14px;font-size:12px}.notice{border-left:3px solid #c58432;background:#fff7e8;padding:14px 18px;border-radius:5px;margin:25px 0;color:#715020}.notice strong{color:#5f3b0b}.summary{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:20px 0}.metric{background:#fff;border:1px solid var(--line);border-radius:12px;padding:18px}.metric .value{font-size:29px;font-weight:720;line-height:1.5;font-variant-numeric:tabular-nums}.metric small{display:block;color:var(--muted);font-size:12px}.panel{background:white;border:1px solid var(--line);border-radius:14px;padding:23px;margin-top:18px}.toolbar{display:flex;align-items:center;gap:12px;justify-content:space-between;flex-wrap:wrap}select,button{border:1px solid #ccd8df;border-radius:7px;background:white;color:var(--ink);font:inherit;padding:7px 12px;cursor:pointer}button:hover{background:#f0f5f8}.legend{display:flex;gap:18px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin:15px 0 8px}.swatch{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:6px}.chart-scroll{overflow-x:auto}.chart{display:block;width:100%;min-width:820px}.footnote{font-size:12px;color:var(--muted)}.two{display:grid;grid-template-columns:1.1fr 1fr;gap:18px}.two .panel{min-width:0}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:10px 9px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:550;white-space:nowrap}td.num{font-variant-numeric:tabular-nums;white-space:nowrap}dl{display:grid;grid-template-columns:125px 1fr;gap:9px;font-size:13px}dt{color:var(--muted)}dd{margin:0;overflow-wrap:anywhere}audio{width:100%;margin:14px 0 2px}blockquote{margin:15px 0 0;border-left:2px solid #b5cdd8;padding:4px 14px;color:var(--muted);font-size:13px}.stages li{padding:6px 0}.stages strong{font-variant-numeric:tabular-nums}.table-scroll{overflow:auto;max-height:410px}.raw{margin-top:15px}summary{cursor:pointer;font-weight:650}.cold{height:11px;background:#f4e7d4;border-radius:8px;margin-top:13px;overflow:hidden}.cold span{display:block;width:100%;height:100%;background:#c28c49}.hint{padding:9px 12px;background:#edf6f2;color:#27624f;border-radius:7px;font-size:13px}.failure{color:#993b39}footer{font-size:12px;color:var(--muted);margin-top:24px}a{color:#34639e}button:focus-visible,select:focus-visible,summary:focus-visible{outline:3px solid #8db9ed;outline-offset:3px}@media(max-width:760px){main{padding:0 16px;margin:25px auto}.top{display:block}.badge{display:inline-block;margin-top:8px}h1{font-size:30px}.summary{grid-template-columns:repeat(2,1fr)}.two{grid-template-columns:1fr;gap:0}.panel{padding:17px}.metric{padding:14px}.metric .value{font-size:25px}}
</style></head><body><main>
<header class="top"><div><div class="eyebrow">YOUZI / VOICE LATENCY LAB</div><h1>LLM → 语音输出</h1><p>真实请求、逐句合成、输出渲染时钟。把等待拆开看。</p></div><div class="badge">临时诊断报告 · 2026.09.08</div></header>
<div id="notice" class="notice"></div>
<div id="protocol" class="notice"></div><section id="cold" class="panel"></section>
<div class="toolbar" style="margin-top:25px"><h2>请求时间线</h2><label>选择实测 <select id="run"></select></label></div>
<section id="summary" class="summary"></section>
<section class="panel"><div class="toolbar"><h2>LLM / TTS / 输出甘特图</h2><button id="zoom">聚焦首句</button></div><div class="legend"><span><i class="swatch" style="background:#3873d6"></i>LLM 文字流</span><span><i class="swatch" style="background:#d8c8ed"></i><span id="waitLegend">TTS 首包等待</span></span><span><i class="swatch" style="background:#8558c3"></i><span id="pcmLegend">PCM 接收（含背压）</span></span><span><i class="swatch" style="background:#1e8c74"></i>输出渲染 → 播放完成</span><span>┄ 已有句子，等待上一句播完</span></div><div class="chart-scroll"><svg id="chart" class="chart" role="img" aria-label="LLM和逐句TTS及音频输出时间线"></svg></div><p class="footnote">横轴从 LLM POST 发出开始计时；绿色起点是混音器首个超过 −60 dBFS 的采样时间，不是麦克风测得的出声时间。悬停图形可查看具体时间。</p><div id="overlap" class="hint"></div></section>
<div class="two"><section class="panel"><h2>第一句，时间花在哪里？</h2><ol id="stages" class="stages"></ol><p class="footnote"><span id="receiveNote">TTS 接收时序应与消费/播放背压区分。</span> 完成回调只用于末尾排空，不用于首声计时。</p></section><section class="panel"><h2>本次条件</h2><dl id="conditions"></dl><h2 style="margin-top:20px">生成音频回听</h2><audio id="audio" controls preload="none"></audio><p class="footnote">合成 PCM 的拼接回放；不是现场录音，不保留句间等待。浏览器回放时间不参与这次计时。</p><blockquote id="text"></blockquote></section></div>
<section class="panel"><h2>逐句明细</h2><div class="table-scroll"><table><thead><tr><th>句子</th><th>文字就绪</th><th>TTS 请求</th><th>首 PCM</th><th>首非静音渲染</th><th>播放排空</th></tr></thead><tbody id="sentences"></tbody></table></div></section>
<section class="panel"><h2>重复请求对照</h2><p class="footnote">相同提示词、temperature=0.3、thinking=false；首轮和重复轮的缓存/输出可能不同，不能用单次差值推断因果或当成稳定性能指标。</p><div class="table-scroll"><table><thead><tr><th>轮次</th><th>首文字</th><th>首 PCM</th><th>首渲染</th><th>LLM 完成</th><th>可见 reasoning</th></tr></thead><tbody id="compare"></tbody></table></div></section>
<section class="panel"><div class="toolbar"><h2>证据与范围</h2><button id="download">下载原始时序 JSON</button></div><ul><li>使用实际本地 /v1/chat/completions 与 /v1/audio/speech，请求携带 stream=true；当前旧语音接口并未按流式实现，已单独标注。编译复用产品的句子分段器。</li><li>专用输出探针使用 AVAudioPlayerNode；100 ms PCM 分块、最多 1.5 秒播放队列。当前句排空后才请求下一句 TTS，与所检查的产品调度策略一致；旧接口回退仅为测量使用，不是修改了客户端协议校验。</li><li>绕过 GUI、聊天历史与工具，不含 ASR、40 ms UI 轮询及布局调度。它不是安装版客户端全链路验收。</li><li>没有打开输入节点或麦克风，没有改音量、输出设备或 thinking 偏好。未验证声学延迟、回声消除或全双工。</li><li>输出 tap 回调可能晚于它携带的音频时间戳；JSON 同时保存采样时刻与观察时刻。两者不要混用。</li></ul><details class="raw"><summary>关键原始事件（展开）</summary><div class="table-scroll"><table><thead><tr><th>事件</th><th>句</th><th>采样/事件时间</th><th>观察时间</th></tr></thead><tbody id="events"></tbody></table></div></details></section>
<footer>这是一份离线、自包含 HTML；无外部脚本，无分析跟踪。数据为 2026 年 9 月 8 日本机实测。软件输出事件 ≠ 声学出声验证。</footer>
</main><script id="data" type="application/json">__DATA__</script><script>
'use strict';
const data=JSON.parse(document.getElementById('data').textContent), $=id=>document.getElementById(id);
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const f=n=>Number.isFinite(n)?n.toFixed(3)+' s':'未测得';
const event=(r,n,s)=>r.events.find(e=>e.event===n&&(s===undefined||e.segment===s));
const t=(r,n,s)=>event(r,n,s)?.seconds;
const valid=data.runs.filter(r=>r.status==='completed');
const runs=valid.length?valid:data.runs;
let selected=0, zoom=false;
$('run').innerHTML=runs.map((r,i)=>`<option value="${i}">${escape(r.label)}</option>`).join('');
$('run').onchange=()=>{selected=Number($('run').value);render()};
$('zoom').onclick=()=>{zoom=!zoom;render()};
if(data.preload){$('cold').innerHTML=`<div class="toolbar"><h2>准备阶段 · TTS 模型加载</h2><strong style="color:#a86b23;font-size:25px">${f(data.preload.seconds)}</strong></div><p>已下载模型的独立显式加载（HTTP ${escape(data.preload.status_code)}）。保留已有模型；此时尚未开始本图的 LLM 请求。<b>不把它算进下面的驻留模型延迟。</b></p><div class="cold"><span></span></div><p class="footnote">这是加载 API 的墙钟实测；没有进一步把权重读取、依赖初始化与内部锁等待分开，尚不能归因到某个子步骤。</p>`}else{$('cold').hidden=true}
const ns='http://www.w3.org/2000/svg';
function svg(tag,attrs,text,parent=$('chart')){let e=document.createElementNS(ns,tag);for(const[k,v]of Object.entries(attrs))e.setAttribute(k,v);if(text!==undefined)e.textContent=text;parent.appendChild(e);return e}
function render(){const r=runs[selected];if(!r)return;
const first=t(r,'first_nonsilent_render',1), pcm=t(r,'first_pcm_byte',1), llm=t(r,'llm_done');
const muted=r.output_device?.mute===1, legacy=r.tts_transport_mode==='buffered_legacy';
$('waitLegend').textContent=legacy?'TTS 整句合成等待':'TTS 首包等待';
$('pcmLegend').textContent=legacy?'完整 PCM 收取（非生成流）':'PCM 接收（含背压）';
$('receiveNote').textContent=legacy?'旧接口网络接收由 URLSession delegate 直接计时；完整音频收到后进入输出队列，不把逐块读取假装成 TTS 生成流。':'流式接口接收结束受播放背压影响，不能当作纯模型计算结束时间。';
$('protocol').innerHTML=legacy?'<strong>当前服务：LLM 流式，但 TTS 仍是整句缓冲返回。</strong> 严格流式 PCM 检查实际失败；下面是明确开启“旧接口测量回退”后的数据，不是原客户端已通过流式协议验收。运行中的语音 schema 没有 stream 字段，返回固定 Content-Length，路由使用整句生成后返回 Response。':'';
$('protocol').hidden=!legacy;
$('notice').innerHTML=muted?'<strong>当前输出设备静音 · 本轮没有实际出声。</strong> 下方测得的是 PCM 接收到输出渲染的时序，不是物理扬声器出声时间。没有擅自解除静音；可解除静音后使用回听控件。':'<strong>物理出声时刻未做声学测量。</strong> 下方是软件输出渲染的实测时间；未打开麦克风，不宣称验证了回声消除或全双工。';
$('summary').innerHTML=[['首段文字',t(r,'first_text'),'从 LLM 请求开始'],['首块 PCM',pcm,'收到字节 ≠ 已出声'],['首非静音渲染',first,muted?'设备静音 · 非实际出声':'混音器采样时间戳'],['LLM 完成',llm,'对照首段语音是否重叠']].map(([l,v,n])=>`<div class="metric"><small>${l}</small><div class="value">${f(v)}</div><small>${n}</small></div>`).join('');
const complete=Number.isFinite(llm)&&Number.isFinite(first);
$('overlap').textContent=complete?(first<llm?`本轮首段语音输出渲染比 LLM 完成早 ${(llm-first).toFixed(3)} 秒：不是等整篇回答结束才启动 TTS。`:'本轮首段渲染晚于 LLM 完成；结合首句就绪、TTS 首包和模型状态定位等待。'):'本轮未获得完整的渲染/LLM 完成事件。';
const ready=t(r,'sentence_ready',1),request=t(r,'tts_request',1),enqueue=t(r,'pcm_enqueued',1),text=t(r,'first_text');
$('stages').innerHTML=[['LLM 请求 → 首文字',text],['首文字 → 首句可朗读',ready-text],['首句就绪 → TTS 请求',request-ready],['TTS 请求 → 首 PCM 字节',pcm-request],[legacy?'首 PCM → 完整接收并开始入队':'首 PCM → 首个 100 ms 音频块入队',enqueue-pcm],['音频入队 → 首非静音输出渲染',first-enqueue]].map(([l,v])=>`<li>${l}<br><strong>${f(v)}</strong></li>`).join('');
const dev=r.output_device||{};
$('conditions').innerHTML=[['聊天模型',r.chat_model],['语音模型',r.tts_model+' / '+r.voice],['thinking','明确关闭；reasoning 字符数 '+(r.reasoning_characters??'未知')],['缓存命中 token',JSON.stringify(r.usage?.prompt_tokens_details??{})],['后端版本标记',data.runtime?.runtime_marker||'未采集'],['TTS 返回方式',legacy?'整句生成后返回完整 PCM':'严格流式契约'],['输出设备',dev.name||'未确认'],['系统静音',dev.mute===1?'是（未改变）':dev.mute===0?'否':'未获取'],['音量',JSON.stringify({master:dev.volume_master,left:dev.volume_left,right:dev.volume_right})],['输出管线延迟',f(dev.mixer_output_presentation_latency_seconds)+'（系统报告；非声学校准）'],['采样',`PCM16 / 24 kHz / 单声道`],['请求时间',new Date(r.date).toLocaleString('zh-CN',{hour12:false})]].map(([l,v])=>`<dt>${escape(l)}</dt><dd>${escape(v)}</dd>`).join('');
$('audio').src=r.audio_data_uri||'';$('text').textContent=r.llm_text||r.error||'';
const ids=[...new Set(r.events.filter(e=>e.event==='sentence_ready').map(e=>e.segment))];
$('sentences').innerHTML=ids.map(i=>`<tr><td><b>${i}.</b> ${escape(event(r,'sentence_ready',i)?.text)}</td>${['sentence_ready','tts_request','first_pcm_byte','first_nonsilent_render','playback_drained'].map(n=>`<td class="num">${f(t(r,n,i))}</td>`).join('')}</tr>`).join('');
$('compare').innerHTML=valid.map(x=>`<tr><td>${escape(x.label)}${x.status!=='completed'?'<br><span class="failure">'+escape(x.error)+'</span>':''}</td>${['first_text','first_pcm_byte','first_nonsilent_render','llm_done'].map(n=>`<td class="num">${f(t(x,n))}</td>`).join('')}<td>${x.reasoning_characters??'—'}</td></tr>`).join('');
const hidden=['buffer_played_back','pcm_enqueued','pcm_network_chunk'];
$('events').innerHTML=r.events.filter(e=>!hidden.includes(e.event)).sort((a,b)=>a.seconds-b.seconds).map(e=>`<tr><td>${escape(e.event)}</td><td>${e.segment??'—'}</td><td class="num">${f(e.seconds)}</td><td class="num">${f(e.observed_seconds)}</td></tr>`).join('');
const chart=$('chart');chart.replaceChildren();
const visibleIds=zoom?ids.slice(0,1):ids;
const left=120,right=970,w=1000,height=115+visibleIds.length*70,maxTime=zoom?Math.max(5,(t(r,'playback_drained',1)||first||5)+.7):Math.max(5,...r.events.map(e=>e.seconds))+.5;
const x=v=>left+(right-left)*Math.min(maxTime,Math.max(0,v))/maxTime;
chart.setAttribute('viewBox',`0 0 ${w} ${height}`);
svg('title',{},`${r.label}：LLM首文字${f(text)}，首非静音渲染${f(first)}，${muted?'系统静音':'未做声学验证'}`);
const step=maxTime<10?1:maxTime<30?5:10;
for(let tick=0;tick<=maxTime;tick+=step){svg('line',{x1:x(tick),x2:x(tick),y1:28,y2:height-12,stroke:'#e6ecef'});svg('text',{x:x(tick),y:18,'text-anchor':'middle',fill:'#6f808b','font-size':11},tick+'s')}
function bar(a,b,y,color,label,h=13,dashed=false){if(!Number.isFinite(a)||!Number.isFinite(b)||a>maxTime||b<a)return;let shape=svg('rect',{x:x(a),y,width:Math.max(1,x(b)-x(a)),height:h,rx:3,fill:color,...(dashed?{'fill-opacity':.25,'stroke':color,'stroke-dasharray':'3 3'}:{})});svg('title',{},`${label}：${f(a)} → ${f(b)}，耗时 ${f(b-a)}`,shape)}
function dot(at,y,color,label){if(!Number.isFinite(at)||at>maxTime)return;let d=svg('circle',{cx:x(at),cy:y,r:4,fill:color,stroke:'white','stroke-width':1.5});svg('title',{},`${label}：${f(at)}`,d)}
svg('text',{x:0,y:57,'font-size':13,fill:'#233949'},'LLM');bar(0,text,44,'#ccd8eb','等待首文字',17);bar(text,llm,44,'#3873d6','LLM 文字流',17);dot(text,52,'#164fa9','首文字');
visibleIds.forEach((id,index)=>{let y=91+index*70;svg('text',{x:0,y:y+12,'font-size':13,fill:'#233949'},'第 '+id+' 句');svg('text',{x:0,y:y+31,'font-size':10,fill:'#788995'},'合成 / 输出');let a=t(r,'sentence_ready',id),b=t(r,'tts_request',id),c=t(r,'first_pcm_byte',id),d=t(r,'tts_eof',id),e=t(r,'first_nonsilent_render',id),g=t(r,'playback_drained',id);bar(a,b,y,'#9aaab3','句子已就绪，等待上一句播放',12,true);bar(b,c,y,'#d8c8ed',legacy?'TTS 整句合成等待':'TTS 首包等待');bar(c,d,y,'#8558c3',legacy?'完整 PCM 收取（非生成流）':'PCM 接收（含背压）');bar(e,g,y+23,'#1e8c74','非静音渲染到播放排空');dot(e,y+29.5,'#136f5c','首非静音渲染');if(e<=maxTime)svg('text',{x:Math.min(x(e)+7,905),y:y+49,'font-size':10,fill:'#377e6d'},f(e));});
$('zoom').textContent=zoom?'查看完整时间线':'聚焦首句';
}
$('download').onclick=()=>{const clean={...data,runs:data.runs.map(({audio_data_uri,...r})=>r)},blob=new Blob([JSON.stringify(clean,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='youzi-voice-latency-events.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};
render();
</script></body></html>'''


def make_report(folder):
    data = collect(folder)
    if not data['runs']:
        raise ValueError('No actual probe results; refusing to fabricate a report')
    payload = json.dumps(data, ensure_ascii=False).replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    out = folder / 'index.html'
    out.write_text(TEMPLATE.replace('__DATA__', payload))
    return out


if __name__ == '__main__':
    print(make_report(Path(sys.argv[1])))
