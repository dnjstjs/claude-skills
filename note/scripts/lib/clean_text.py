#!/usr/bin/env python3
"""stdin의 마크다운 텍스트를 한 줄로 정제해 stdout으로 낸다.

사용법: clean_text.py <최대_글자수>
- 코드블록(``` ... ```)을 공백으로 치환
- 마크다운 기호(* _ ` # >) 제거
- 모든 공백/개행을 단일 공백으로 접음
- 앞에서 <최대_글자수> 글자만 남김 (바이트가 아닌 글자 기준이라 한글이 깨지지 않음)
"""
import re
import sys

def main() -> int:
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    text = sys.stdin.read()
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"[*_`#>]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    sys.stdout.write(text[:limit])
    return 0

if __name__ == "__main__":
    sys.exit(main())
