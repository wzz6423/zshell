import { language, languageNames, type Language } from './i18n'

const fields = ['language', 'docs', 'changelog', 'download', 'search', 'closeSearch', 'noResults', 'openSidebar', 'closeSidebar', 'collapseSidebar', 'toc', 'noHeadings', 'previous', 'next', 'copyText', 'copiedText', 'copyLink', 'copiedLink', 'menu', 'fallback', 'notFound', 'backHome', 'searchError', 'retry'] as const
type UiCopy = Record<(typeof fields)[number], string>
type Labels = [string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string, string]
const labels: Record<Language, Labels> = {
  en: ['Language', 'Docs', 'Changelog', 'Download', 'Search', 'Close search', 'No results found', 'Open sidebar', 'Close sidebar', 'Collapse sidebar', 'On this page', 'No headings', 'Previous page', 'Next page', 'Copy text', 'Text copied', 'Copy link', 'Link copied', 'Toggle menu', 'This page is not available in {language} yet. Showing the English version.', 'Page not found', 'Back to home', 'Search could not be loaded.', 'Retry'],
  zh: ['语言', '文档', '更新日志', '下载', '搜索', '关闭搜索', '未找到结果', '打开侧边栏', '关闭侧边栏', '折叠侧边栏', '本页目录', '没有标题', '上一页', '下一页', '复制文本', '已复制文本', '复制链接', '已复制链接', '切换菜单', '此页面暂无{language}译文，当前显示英文版本。', '页面未找到', '返回首页', '无法加载搜索。', '重试'],
  'zh-Hant': ['語言', '文件', '更新日誌', '下載', '搜尋', '關閉搜尋', '找不到結果', '開啟側邊欄', '關閉側邊欄', '收合側邊欄', '本頁目錄', '沒有標題', '上一頁', '下一頁', '複製文字', '已複製文字', '複製連結', '已複製連結', '切換選單', '此頁面尚無{language}譯文，目前顯示英文版本。', '找不到頁面', '返回首頁', '無法載入搜尋。', '重試'],
  ja: ['言語', 'ドキュメント', '更新履歴', 'ダウンロード', '検索', '検索を閉じる', '結果が見つかりません', 'サイドバーを開く', 'サイドバーを閉じる', 'サイドバーを折りたたむ', 'このページの内容', '見出しはありません', '前のページ', '次のページ', 'テキストをコピー', 'コピーしました', 'リンクをコピー', 'リンクをコピーしました', 'メニューを切り替える', 'このページの{language}訳はまだありません。英語版を表示しています。', 'ページが見つかりません', 'ホームに戻る', '検索を読み込めませんでした。', '再試行'],
  ko: ['언어', '문서', '변경 기록', '다운로드', '검색', '검색 닫기', '검색 결과가 없습니다', '사이드바 열기', '사이드바 닫기', '사이드바 접기', '이 페이지의 내용', '제목이 없습니다', '이전 페이지', '다음 페이지', '텍스트 복사', '텍스트 복사됨', '링크 복사', '링크 복사됨', '메뉴 전환', '이 페이지의 {language} 번역이 아직 없습니다. 영어 버전을 표시합니다.', '페이지를 찾을 수 없습니다', '홈으로 돌아가기', '검색을 불러오지 못했습니다.', '다시 시도'],
  fr: ['Langue', 'Documentation', 'Historique des versions', 'Télécharger', 'Rechercher', 'Fermer la recherche', 'Aucun résultat', 'Ouvrir la barre latérale', 'Fermer la barre latérale', 'Réduire la barre latérale', 'Sur cette page', 'Aucun titre', 'Page précédente', 'Page suivante', 'Copier le texte', 'Texte copié', 'Copier le lien', 'Lien copié', 'Afficher ou masquer le menu', 'Cette page n’est pas encore disponible en {language}. La version anglaise est affichée.', 'Page introuvable', 'Retour à l’accueil', 'Impossible de charger la recherche.', 'Réessayer'],
  de: ['Sprache', 'Dokumentation', 'Änderungsprotokoll', 'Herunterladen', 'Suchen', 'Suche schließen', 'Keine Ergebnisse gefunden', 'Seitenleiste öffnen', 'Seitenleiste schließen', 'Seitenleiste einklappen', 'Auf dieser Seite', 'Keine Überschriften', 'Vorherige Seite', 'Nächste Seite', 'Text kopieren', 'Text kopiert', 'Link kopieren', 'Link kopiert', 'Menü umschalten', 'Diese Seite ist noch nicht auf {language} verfügbar. Die englische Version wird angezeigt.', 'Seite nicht gefunden', 'Zur Startseite', 'Die Suche konnte nicht geladen werden.', 'Erneut versuchen'],
  es: ['Idioma', 'Documentación', 'Historial de cambios', 'Descargar', 'Buscar', 'Cerrar búsqueda', 'No se encontraron resultados', 'Abrir barra lateral', 'Cerrar barra lateral', 'Contraer barra lateral', 'En esta página', 'No hay encabezados', 'Página anterior', 'Página siguiente', 'Copiar texto', 'Texto copiado', 'Copiar enlace', 'Enlace copiado', 'Alternar menú', 'Esta página aún no está disponible en {language}. Se muestra la versión en inglés.', 'Página no encontrada', 'Volver al inicio', 'No se pudo cargar la búsqueda.', 'Reintentar'],
  'pt-BR': ['Idioma', 'Documentação', 'Histórico de alterações', 'Baixar', 'Buscar', 'Fechar busca', 'Nenhum resultado encontrado', 'Abrir barra lateral', 'Fechar barra lateral', 'Recolher barra lateral', 'Nesta página', 'Nenhum título', 'Página anterior', 'Próxima página', 'Copiar texto', 'Texto copiado', 'Copiar link', 'Link copiado', 'Alternar menu', 'Esta página ainda não está disponível em {language}. A versão em inglês está sendo exibida.', 'Página não encontrada', 'Voltar ao início', 'Não foi possível carregar a busca.', 'Tentar novamente'],
  it: ['Lingua', 'Documentazione', 'Registro delle modifiche', 'Scarica', 'Cerca', 'Chiudi ricerca', 'Nessun risultato trovato', 'Apri barra laterale', 'Chiudi barra laterale', 'Comprimi barra laterale', 'In questa pagina', 'Nessun titolo', 'Pagina precedente', 'Pagina successiva', 'Copia testo', 'Testo copiato', 'Copia link', 'Link copiato', 'Mostra o nascondi menu', 'Questa pagina non è ancora disponibile in {language}. Viene mostrata la versione inglese.', 'Pagina non trovata', 'Torna alla home', 'Impossibile caricare la ricerca.', 'Riprova'],
  nl: ['Taal', 'Documentatie', 'Wijzigingslogboek', 'Downloaden', 'Zoeken', 'Zoeken sluiten', 'Geen resultaten gevonden', 'Zijbalk openen', 'Zijbalk sluiten', 'Zijbalk inklappen', 'Op deze pagina', 'Geen koppen', 'Vorige pagina', 'Volgende pagina', 'Tekst kopiëren', 'Tekst gekopieerd', 'Link kopiëren', 'Link gekopieerd', 'Menu wisselen', 'Deze pagina is nog niet beschikbaar in {language}. De Engelse versie wordt getoond.', 'Pagina niet gevonden', 'Terug naar de startpagina', 'Zoeken kon niet worden geladen.', 'Opnieuw proberen'],
  ru: ['Язык', 'Документация', 'История изменений', 'Скачать', 'Поиск', 'Закрыть поиск', 'Ничего не найдено', 'Открыть боковую панель', 'Закрыть боковую панель', 'Свернуть боковую панель', 'На этой странице', 'Нет заголовков', 'Предыдущая страница', 'Следующая страница', 'Копировать текст', 'Текст скопирован', 'Копировать ссылку', 'Ссылка скопирована', 'Переключить меню', 'Перевод этой страницы на {language} пока недоступен. Показана английская версия.', 'Страница не найдена', 'На главную', 'Не удалось загрузить поиск.', 'Повторить'],
  ar: ['اللغة', 'الوثائق', 'سجل التغييرات', 'تنزيل', 'بحث', 'إغلاق البحث', 'لم يتم العثور على نتائج', 'فتح الشريط الجانبي', 'إغلاق الشريط الجانبي', 'طي الشريط الجانبي', 'في هذه الصفحة', 'لا توجد عناوين', 'الصفحة السابقة', 'الصفحة التالية', 'نسخ النص', 'تم نسخ النص', 'نسخ الرابط', 'تم نسخ الرابط', 'تبديل القائمة', 'هذه الصفحة غير متاحة بعد باللغة {language}. تُعرض النسخة الإنجليزية.', 'الصفحة غير موجودة', 'العودة إلى الرئيسية', 'تعذر تحميل البحث.', 'إعادة المحاولة'],
  th: ['ภาษา', 'เอกสาร', 'บันทึกการเปลี่ยนแปลง', 'ดาวน์โหลด', 'ค้นหา', 'ปิดการค้นหา', 'ไม่พบผลลัพธ์', 'เปิดแถบด้านข้าง', 'ปิดแถบด้านข้าง', 'ยุบแถบด้านข้าง', 'ในหน้านี้', 'ไม่มีหัวข้อ', 'หน้าก่อนหน้า', 'หน้าถัดไป', 'คัดลอกข้อความ', 'คัดลอกข้อความแล้ว', 'คัดลอกลิงก์', 'คัดลอกลิงก์แล้ว', 'สลับเมนู', 'หน้านี้ยังไม่มีฉบับ{language} จึงแสดงฉบับภาษาอังกฤษ', 'ไม่พบหน้า', 'กลับหน้าหลัก', 'โหลดการค้นหาไม่สำเร็จ', 'ลองอีกครั้ง'],
  id: ['Bahasa', 'Dokumentasi', 'Catatan perubahan', 'Unduh', 'Cari', 'Tutup pencarian', 'Tidak ada hasil', 'Buka bilah samping', 'Tutup bilah samping', 'Ciutkan bilah samping', 'Di halaman ini', 'Tidak ada judul', 'Halaman sebelumnya', 'Halaman berikutnya', 'Salin teks', 'Teks disalin', 'Salin tautan', 'Tautan disalin', 'Alihkan menu', 'Halaman ini belum tersedia dalam {language}. Versi bahasa Inggris ditampilkan.', 'Halaman tidak ditemukan', 'Kembali ke beranda', 'Pencarian tidak dapat dimuat.', 'Coba lagi'],
  vi: ['Ngôn ngữ', 'Tài liệu', 'Nhật ký thay đổi', 'Tải xuống', 'Tìm kiếm', 'Đóng tìm kiếm', 'Không tìm thấy kết quả', 'Mở thanh bên', 'Đóng thanh bên', 'Thu gọn thanh bên', 'Trong trang này', 'Không có tiêu đề', 'Trang trước', 'Trang tiếp', 'Sao chép văn bản', 'Đã sao chép văn bản', 'Sao chép liên kết', 'Đã sao chép liên kết', 'Bật tắt menu', 'Trang này chưa có bản dịch {language}. Đang hiển thị bản tiếng Anh.', 'Không tìm thấy trang', 'Về trang chủ', 'Không thể tải tìm kiếm.', 'Thử lại'],
  tr: ['Dil', 'Belgeler', 'Değişiklik günlüğü', 'İndir', 'Ara', 'Aramayı kapat', 'Sonuç bulunamadı', 'Kenar çubuğunu aç', 'Kenar çubuğunu kapat', 'Kenar çubuğunu daralt', 'Bu sayfada', 'Başlık yok', 'Önceki sayfa', 'Sonraki sayfa', 'Metni kopyala', 'Metin kopyalandı', 'Bağlantıyı kopyala', 'Bağlantı kopyalandı', 'Menüyü aç veya kapat', 'Bu sayfanın {language} çevirisi henüz yok. İngilizce sürüm gösteriliyor.', 'Sayfa bulunamadı', 'Ana sayfaya dön', 'Arama yüklenemedi.', 'Yeniden dene'],
}

export function uiCopy(lang: string): UiCopy {
  return Object.fromEntries(fields.map((key, index) => [key, labels[language(lang)][index]])) as UiCopy
}

export function docsTranslations(lang: string): Record<string, string> {
  const t = uiCopy(lang)
  return {
    displayName: languageNames[language(lang)],
    'Choose a language(language switcher)': t.language,
    'Choose a language(language switcher)(aria-label)': t.language,
    'Search(search dialog)': t.search,
    'Search(search trigger)': t.search,
    'Open Search(search trigger)(aria-label)': t.search,
    'Close Search(search dialog)(aria-label)': t.closeSearch,
    'No results found(search dialog)': t.noResults,
    'Open Sidebar(sidebar)(aria-label)': t.openSidebar,
    'Close Sidebar(aria-label)': t.closeSidebar,
    'Close Sidebar(sidebar)(aria-label)': t.closeSidebar,
    'Collapse Sidebar(sidebar)(aria-label)': t.collapseSidebar,
    'Hide Sidebar(sidebar)': t.closeSidebar,
    'Show Sidebar(sidebar)': t.openSidebar,
    'Toggle Menu(mobile menu)(aria-label)': t.menu,
    'On this page(table of contents)': t.toc,
    'Table of Contents(inline table of contents)': t.toc,
    'No Headings(table of contents)': t.noHeadings,
    'Previous Page(pagination)': t.previous,
    'Next Page(pagination)': t.next,
    'Copy Text(code block)(aria-label)': t.copyText,
    'Copied Text(code block)(aria-label)': t.copiedText,
    'Copy Anchor Link(heading anchor)(aria-label)': t.copyLink,
    'Copied Anchor Link(heading anchor)(aria-label)': t.copiedLink,
    'Copy Link(accordion)(aria-label)': t.copyLink,
    'Copied Link(accordion)(aria-label)': t.copiedLink,
    'Back to Home(404 page)': t.backHome,
    'Page Not Found(404 page)': t.notFound,
  }
}
