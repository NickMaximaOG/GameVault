export class ApiError extends Error { constructor(status, code, message) { super(message); this.status=status; this.code=code; } }
export async function api(method, path, body) {
  let res;
  try { res=await fetch('/api/v1'+path,{method,credentials:'same-origin',headers:{'Content-Type':'application/json','X-Requested-With':'gamevault'},body:body===undefined?undefined:JSON.stringify(body)}); }
  catch { throw new ApiError(0,'network','Cannot reach GameVault. Check that the backend is running.'); }
  if(res.status===204)return null;
  let data={}; try{data=await res.json()}catch{}
  if(!res.ok) throw new ApiError(res.status,data?.error?.code||'error',data?.error?.message||`Request failed (${res.status})`);
  return data;
}
export const qs=o=>{const p=new URLSearchParams();Object.entries(o).forEach(([k,v])=>{if(v!==''&&v!==null&&v!==undefined)p.set(k,v)});return p.toString()?'?'+p.toString():''};
