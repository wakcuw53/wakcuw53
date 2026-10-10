from pathlib import Path
root=Path('.')
hero=root/'packages/ui/src/assets/Z.svg'
hero.write_text('''<svg width="436" height="360" viewBox="0 0 436 360" xmlns="http://www.w3.org/2000/svg"><text x="218" y="276" text-anchor="middle" fill="none" stroke="#707780" stroke-opacity=".20" stroke-width="3" font-size="315" font-weight="850" font-family="Arial,sans-serif">M</text></svg>''',encoding='utf-8')
logo=root/'packages/ui/src/assets/provider-icons/logo-zai.svg'
logo.write_text('''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect x="1" y="1" width="62" height="62" rx="16" fill="#121820" stroke="#8ba4ba"/><path d="M15 46V18L32 38 49 18V46" fill="none" stroke="#f4f7fb" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/></svg>''',encoding='utf-8')
startup=root/'packages/ui/src/root/RootStartupLoading.tsx'
s=startup.read_text(encoding='utf-8')
begin=s.index('    <svg',s.index('function ZCodeStartupLogo'))
end=s.index('</svg>',begin)+len('</svg>')
s=s[:begin]+'''    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 218" className={cn("shrink-0 text-current", className)} aria-hidden="true" focusable="false">
      {animated ? <animate attributeName="opacity" begin="3s" dur="1.8s" repeatCount="indefinite" values="1;0.4;1" /> : null}
      <text x="128" y="177" textAnchor="middle" fontFamily="Arial, sans-serif" fontSize="205" fontWeight="850" fill="currentColor">M</text>
    </svg>'''+s[end:]
startup.write_text(s,encoding='utf-8')
loc=root/'packages/ui/src/i18n/locales/en-US.ts'
loc.write_text(loc.read_text(encoding='utf-8').replace('ZCode','MaksAI'),encoding='utf-8')
web=root/'packages/web/index.html'
web.write_text(web.read_text(encoding='utf-8').replace('<title>ZCode</title>','<title>MaksAI</title>'),encoding='utf-8')
print('MaksAI branding files patched')
