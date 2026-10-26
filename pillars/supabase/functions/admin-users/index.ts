// Deploy: supabase functions deploy admin-users
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4'
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, content-type, apikey, x-client-info'}
const norm=(p:string)=>'256'+p.replace(/\D/g,'').replace(/^(256|0)/,'')
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors})
 const url=Deno.env.get('SUPABASE_URL')!,svc=createClient(url,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
 const out=(o:unknown,s=200)=>new Response(JSON.stringify(o),{status:s,headers:{...cors,'content-type':'application/json'}})
 const{data:{user}}=await svc.auth.getUser((req.headers.get('Authorization')||'').replace('Bearer ',''))
 if(!user)return out({error:'Sign in first'},401)
 const{data:caller}=await svc.from('staff').select('name,role').eq('user_id',user.id).single()
 if(caller?.role!=='admin')return out({error:'Only the Super Admin can do this'},403)
 const b=await req.json(),log=(t:string)=>svc.from('audit').insert({who:caller.name,action:t})
 if((b.action==='create'||b.action==='reset')&&!/^\d{6}$/.test(b.pin||''))return out({error:'PIN must be 6 digits'},400)
 if(b.action==='create'){
  const{data:m}=await svc.from('members').select('id,name,phone,acct,status').eq('id',b.member_id).single()
  if(!m||m.status!=='Active')return out({error:'Member not found or inactive'},400)
  if(!m.phone)return out({error:'Add this member’s phone number first (Members > Edit)'},400)
  const{data:u,error}=await svc.auth.admin.createUser({email:norm(m.phone)+'@pillars.local',password:b.pin,email_confirm:true})
  if(error)return out({error:error.message},400)
  await svc.from('staff').insert({user_id:u.user.id,member_id:m.id,name:m.name,role:b.role}); await log(`Gave ${m.acct} access as ${b.role}`)
 }else{
  const{data:t}=await svc.from('staff').select('user_id,name,role').eq('user_id',b.user_id).single()
  if(!t)return out({error:'User not found'},404)
  if(b.action!=='reset'&&t.user_id===user.id)return out({error:'You cannot change your own access'},400)
  if(b.action==='reset'){await svc.auth.admin.updateUserById(t.user_id,{password:b.pin});await log('Reset PIN of '+t.name)}
  else{
   if(t.role==='admin'&&(b.action==='remove'||b.role!=='admin')){const{count}=await svc.from('staff').select('*',{count:'exact',head:true}).eq('role','admin');if((count||0)<2)return out({error:'Keep at least one Super Admin'},400)}
   if(b.action==='role'){await svc.from('staff').update({role:b.role}).eq('user_id',t.user_id);await log(`Changed role of ${t.name} to ${b.role}`)}
   else if(b.action==='remove'){await svc.auth.admin.deleteUser(t.user_id);await log('Removed access of '+t.name)}
  }
 }
 return out({ok:true})
})
