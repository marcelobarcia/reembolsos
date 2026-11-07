import {build} from 'esbuild';
import {cp,mkdir,rm} from 'node:fs/promises';
await rm('dist',{recursive:true,force:true});await mkdir('dist');await cp('public','dist',{recursive:true});
await build({entryPoints:['src/app.js'],bundle:true,format:'esm',target:['safari16','chrome110'],outfile:'dist/app.js',minify:true});
