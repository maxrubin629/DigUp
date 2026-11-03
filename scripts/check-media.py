#!/usr/bin/env python3
"""Labelled retrieval checks through the real MCP protocol, using the disposable media testbed."""
import importlib.util, json, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mcp_check",Path(__file__).with_name("check-mcp.py"))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
server,config,folder,output=map(Path,sys.argv[1:])
client=module.Client(str(server.resolve()),str(config.resolve()))
checks=[]
try:
    topics=[
        ("volcanic geology magma","note-00.txt"),
        ("baking sourdough bread","note-01.txt"),
        ("ocean tides and whales","note-02.txt"),
        ("quantum particles photons","note-03.txt"),
        ("Roman emperors history","note-04.txt"),
        ("database transactions locks","note-05.txt"),
        ("gardening compost","note-06.txt"),
        ("basketball playoffs","note-07.txt"),
        ("aircraft turbine engines","note-08.txt"),
        ("nautical sailing charts","note-09.txt"),
    ]
    queries=[(text,{"text":text},target) for text,target in topics]
    queries += [
        ("image example: landscape",{"image_path":str((folder/"photo.jpg").resolve())},"photo.jpg"),
        ("image example: interface",{"image_path":str((folder/"screen.png").resolve())},"screen.png"),
        ("audio example",{"audio_path":str((folder/"speech.wav").resolve())},"speech.wav"),
        ("selected later audio",{"audio_path":str((folder/"long-recording.wav").resolve()),
                                "start_seconds":31,"duration_seconds":4},"speech.wav"),
    ]
    for label,args,target in queries:
        result=client.tool("digup_search_files",{**args,"limit":5})["structuredContent"]
        names=[Path(r["path"]).name for r in result["results"]]
        assert target in names,(label,target,names)
        checks.append({"query":label,"expected":target,"rank":names.index(target)+1})
    for args in [
        {"audio_path":str((folder/"long-recording.wav").resolve())},
        {"audio_path":str((folder/"long-recording.wav").resolve()),"start_seconds":0,"duration_seconds":31},
        {"audio_path":str((folder/"silence.wav").resolve())},
        {"image_path":str((folder/"broken.png").resolve())},
    ]:
        client.tool("digup_search_files",args,error=True)
    output.write_text(json.dumps({"retrieval":checks,"invalid_media_checks":4},indent=2))
    print(json.dumps({"labelled_queries_passed":len(checks),"invalid_media_checks":4,
                      "top1":sum(r["rank"]==1 for r in checks),"top5":len(checks)}))
finally: client.close()
